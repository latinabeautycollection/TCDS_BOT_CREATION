import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { BrightDataClient } from "./brightdata.js";
import { CanonicalDatabase } from "./canonical-db.js";
import { loadConfig } from "./config.js";
import { discoverBhPhotoInputs } from "./discovery.js";
import { readRecordFile } from "./files.js";
import { createLogger } from "./logger.js";

function value(name: string, fallback?: string): string | undefined {
  const prefix = `--${name}=`;
  return process.argv.find(arg => arg.startsWith(prefix))?.slice(prefix.length) ?? fallback;
}

async function loadSeeds(path: string): Promise<Array<{url: string}>> {
  const parsed = JSON.parse(await readFile(path, "utf8")) as { input?: unknown };
  if (!Array.isArray(parsed.input)) throw new Error("Input file must contain an input array");
  const seeds = parsed.input.filter((item): item is {url: string} =>
    Boolean(item && typeof item === "object" &&
      typeof (item as {url?: unknown}).url === "string" &&
      (item as {url: string}).url.startsWith("https://")));
  if (!seeds.length) throw new Error("Input file contains no valid HTTPS URLs");
  return seeds;
}

async function main(): Promise<void> {
  const cfg = loadConfig();
  const log = createLogger(cfg);
  const db = new CanonicalDatabase(cfg);
  const bright = new BrightDataClient(cfg, log);
  const command = process.argv[2] ?? "run";
  let locked = false;

  try {
    if (command === "health") {
      log.info({ database: await db.health() }, "health_ok");
      return;
    }
    if (!["run", "ingest-file"].includes(command)) {
      throw new Error("Supported commands: run, ingest-file, health");
    }
    locked = await db.lock();
    if (!locked) throw new Error("Another B&H ingest is already running");

    let rows: unknown[];
    let snapshotId: string | null = null;
    let discovered = 0;

    if (command === "ingest-file") {
      const file = value("file");
      if (!file) throw new Error("Usage: npm run ingest:file -- --file=/path/results.json");
      rows = await readRecordFile(resolve(file));
      discovered = rows.length;
    } else {
      const seeds = await loadSeeds(resolve(value("inputs", "config/bhphoto.inputs.json")!));
      const input = await discoverBhPhotoInputs(
        seeds,
        url => bright.fetchWebUnlockerHtml(url),
        cfg.BRIGHT_DATA_LIMIT_PER_INPUT
      );
      discovered = input.length;
      log.info({ seed_count: seeds.length, discovered_count: discovered }, "bhphoto_discovery_complete");
      const trigger = await bright.trigger(input, 1);
      snapshotId = trigger.snapshotId;
      await bright.wait(snapshotId);
      rows = await bright.download(snapshotId);
    }

    const runId = await db.startRun(discovered, {
      source: "brightdata",
      dataset_id: cfg.BRIGHT_DATA_DATASET_ID,
      snapshot_id: snapshotId,
      mode: command === "run" ? "category_discovery_to_pdp" : "file_ingest"
    });
    const counts = await db.ingest(runId, rows, snapshotId);
    await db.complete(runId, rows.length, counts, { snapshot_id: snapshotId, discovered });
    log.info({ run_id: runId, snapshot_id: snapshotId, total_rows: rows.length, ...counts }, "collection_complete");
  } finally {
    if (locked) await db.unlock().catch(() => undefined);
    await db.close();
  }
}

main().catch(error => {
  console.error(JSON.stringify({
    ts: new Date().toISOString(),
    level: "fatal",
    message: error instanceof Error ? error.message : String(error)
  }));
  process.exitCode = 1;
});
