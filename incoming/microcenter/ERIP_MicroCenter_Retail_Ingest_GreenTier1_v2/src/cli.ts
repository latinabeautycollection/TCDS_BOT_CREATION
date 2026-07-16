import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { BrightDataClient } from "./brightdata.js";
import { loadConfig } from "./config.js";
import { Database } from "./db.js";
import { readRecordFile } from "./files.js";
import { ingestRecords } from "./ingest.js";
import { createLogger } from "./logger.js";
import { sha256, uuid } from "./util.js";
import { isSearchOrCategoryUrl, discoverProductUrls } from "./discovery.js";

function value(name: string, fallback?: string): string | undefined {
  const prefix = `--${name}=`;
  return process.argv.find(x => x.startsWith(prefix))?.slice(prefix.length) ?? fallback;
}

async function loadInputs(path: string): Promise<Array<{url:string}>> {
  const parsed = JSON.parse(await readFile(path, "utf8")) as {input?: unknown};
  if (!Array.isArray(parsed.input)) throw new Error("Input file must contain an input array.");
  const input = parsed.input.filter((x): x is {url:string} =>
    Boolean(x && typeof x === "object" && typeof (x as {url?:unknown}).url === "string" &&
      (x as {url:string}).url.startsWith("https://")));
  if (!input.length) throw new Error("Input file contains no valid HTTPS URLs.");
  return input;
}

async function main() {
  const cfg = loadConfig();
  const log = createLogger(cfg);
  const db = new Database(cfg, log);
  const bright = new BrightDataClient(cfg, log);
  const command = process.argv[2] ?? "run";
  const lockKey = `${cfg.RETAIL_PLATFORM_CODE}:daily-ingest`;
  let locked = false;

  try {
    if (command === "health") {
      log.info({ database: await db.health() }, "health_ok");
      return;
    }

    locked = await db.acquireAdvisoryLock(lockKey);
    if (!locked) throw new Error(`Another ${cfg.RETAIL_PLATFORM_CODE} ingest is already running.`);

    const platformId = await db.platformId();

    if (command === "ingest-file") {
      const file = value("file");
      if (!file) throw new Error("Usage: npm run ingest:file -- --file=/path/results.json");
      const records = await readRecordFile(resolve(file));
      const runId = uuid();
      const runKey = sha256({ command, file: resolve(file), hour: new Date().toISOString().slice(0,13) });
      await db.createRun({ runId, platformId, runKey, status:"ingesting", inputCount:0, payload:{file:resolve(file)} });
      try {
        const r = await ingestRecords({ cfg, db, log, runId, platformId, records });
        await db.updateRun(runId, {
          status:"completed", received_record_count:records.length,
          inserted_raw_count:r.rawInserted, inserted_offer_count:r.offersInserted,
          duplicate_count:r.duplicates, quarantine_count:r.quarantined,
          metrics:{quarantine_rate:r.quarantineRate, duplicate_rate:r.duplicateRate},
          completed_at:new Date().toISOString()
        });
      } catch (e) {
        await db.updateRun(runId, { status:"failed", error_message:e instanceof Error?e.message:String(e), completed_at:new Date().toISOString() });
        throw e;
      }
      return;
    }

    if (command === "resume") {
      const snapshotId = value("snapshot-id");
      const runId = value("run-id");
      if (!snapshotId || !runId) throw new Error("Usage: npm run resume -- --run-id=<uuid> --snapshot-id=<id>");
      await bright.wait(snapshotId);
      const records = await bright.download(snapshotId);
      const r = await ingestRecords({ cfg, db, log, runId, platformId, records });
      await db.updateRun(runId, {
        status:"completed", received_record_count:records.length,
        inserted_raw_count:r.rawInserted, inserted_offer_count:r.offersInserted,
        duplicate_count:r.duplicates, quarantine_count:r.quarantined,
        metrics:{quarantine_rate:r.quarantineRate, duplicate_rate:r.duplicateRate},
        completed_at:new Date().toISOString()
      });
      return;
    }

    const inputFile = resolve(value("inputs", "config/microcenter.inputs.json")!);
    const input = await loadInputs(inputFile);
    const runId = uuid();
    const runKey = sha256({
      platform: cfg.RETAIL_PLATFORM_CODE,
      dataset: cfg.BRIGHT_DATA_DATASET_ID,
      input,
      date: new Date().toISOString().slice(0,10)
    });
    await db.createRun({
      runId, platformId, runKey, status:"triggering", inputCount:input.length,
      payload:{input, limit_per_input:cfg.BRIGHT_DATA_LIMIT_PER_INPUT}
    });

    try {
      const searchUrls: string[] = [];
      const directProductUrls: string[] = [];
      for (const item of input) {
        if (isSearchOrCategoryUrl(item.url)) {
          searchUrls.push(item.url);
        } else {
          directProductUrls.push(item.url);
        }
      }

      let discoveredProductUrls: string[] = [];
      if (searchUrls.length > 0) {
        log.info({ count: searchUrls.length }, "discovery_started");
        discoveredProductUrls = await discoverProductUrls(bright, searchUrls, cfg.BRIGHT_DATA_LIMIT_PER_INPUT, log);
        log.info({ count: discoveredProductUrls.length }, "discovery_finished");
      }

      const combinedProductUrls = Array.from(new Set([...directProductUrls, ...discoveredProductUrls]));
      if (combinedProductUrls.length === 0) {
        throw new Error("No product URLs were discovered or provided to scrape.");
      }

      const datasetInput = combinedProductUrls.map((url) => ({ url }));

      const trigger = await bright.trigger(datasetInput);
      await db.updateRun(runId, {
        status:"triggered", snapshot_id:trigger.snapshotId, provider_response:trigger.providerResponse
      });
      log.info({ run_id:runId, snapshot_id:trigger.snapshotId }, "collection_triggered");

      if (command === "trigger") {
        console.log(JSON.stringify({runId, snapshotId:trigger.snapshotId}, null, 2));
        return;
      }

      await db.updateRun(runId, {status:"collecting"});
      const progress = await bright.wait(trigger.snapshotId);
      await db.updateRun(runId, {status:"downloading", provider_response:progress});
      const records = await bright.download(trigger.snapshotId);
      await db.updateRun(runId, {status:"ingesting", received_record_count:records.length});
      const r = await ingestRecords({ cfg, db, log, runId, platformId, records });
      await db.updateRun(runId, {
        status:"completed", inserted_raw_count:r.rawInserted, inserted_offer_count:r.offersInserted,
        duplicate_count:r.duplicates, quarantine_count:r.quarantined,
        metrics:{quarantine_rate:r.quarantineRate, duplicate_rate:r.duplicateRate},
        completed_at:new Date().toISOString()
      });
      log.info({run_id:runId, snapshot_id:trigger.snapshotId, records:records.length, ...r}, "collection_completed");
    } catch (e) {
      await db.updateRun(runId, {
        status:"failed", error_code:"INGEST_FAILURE",
        error_message:e instanceof Error?e.message:String(e),
        completed_at:new Date().toISOString()
      }).catch(updateError => log.error({error:updateError}, "failed_to_record_run_failure"));
      throw e;
    }
  } finally {
    if (locked) await db.releaseAdvisoryLock(lockKey).catch(() => undefined);
    await db.close();
  }
}

main().catch(error => {
  console.error(JSON.stringify({ts:new Date().toISOString(),level:"fatal",message:error instanceof Error?error.message:String(error)}));
  process.exitCode = 1;
});
