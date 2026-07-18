import fs from "node:fs/promises";
import path from "node:path";
import { config } from "./config.js";
import { log } from "./log.js";
import { triggerDataset, waitForSnapshot, downloadSnapshot } from "./brightdata.js";
import { NeweggRecordSchema } from "./types.js";
import { platformAndConfig, createRun, finishRun, deadLetter, ingestRecord, pool } from "./db.js";
import { isNeweggUrl, sha256, stableJson } from "./util.js";
import { unlockNeweggPage } from "./unlocker.js";
import { discoverNeweggProducts, findUnreturnedNeweggInputs } from "./discovery.js";

async function localDlq(payload: unknown, code: string, error: unknown) {
  await fs.mkdir(config.DLQ_DIRECTORY, { recursive: true });
  await fs.writeFile(
    path.join(config.DLQ_DIRECTORY, `${Date.now()}-${code}-${sha256(stableJson(payload)).slice(0, 12)}.json`),
    JSON.stringify({ ts: new Date().toISOString(), code, error: String(error), payload }, null, 2)
  );
}

async function mapLimit<T>(items: T[], limit: number, fn: (item: T) => Promise<void>) {
  let index = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (true) {
      const current = index++;
      if (current >= items.length) return;
      await fn(items[current]!);
    }
  }));
}

function providerError(raw: unknown): { code: string; message: string } | null {
  if (!raw || typeof raw !== "object") return null;
  const row = raw as Record<string, unknown>;
  if (!row.error && !row.error_code) return null;
  return {
    code: `PROVIDER_${String(row.error_code ?? "unknown")}`,
    message: String(row.error ?? "Bright Data provider error")
  };
}

async function main() {
  const badUrl = config.seedUrls.find(url => !isNeweggUrl(url));
  if (badUrl) throw new Error(`Rejected non-Newegg seed URL: ${badUrl}`);

  const discovered = await discoverNeweggProducts(
    config.seedUrls,
    async url => (await unlockNeweggPage(url)).body,
    config.NEWEGG_LIMIT_PER_INPUT
  );
  const urls = discovered.map(product => product.url);
  const { platformId, configId } = await platformAndConfig();
  const runKey = `newegg:${new Date().toISOString()}:${sha256(urls.join("|")).slice(0, 12)}`;
  const stats = { collected: 0, failed: 0, skipped: 0 };
  let runId = "";

  try {
    runId = await createRun(platformId, configId, runKey, urls);
    log("info", "newegg_run_started", { runId, seeds: config.seedUrls, discovered: urls.length });
    const snapshotId = await triggerDataset(urls);
    log("info", "dataset_triggered", { runId, snapshotId });
    await waitForSnapshot(snapshotId);
    const rows = await downloadSnapshot(snapshotId);
    log("info", "snapshot_downloaded", { runId, snapshotId, rows: rows.length });
    if (!rows.length) throw new Error("NEWEGG_SNAPSHOT_EMPTY");

    const unreturnedInputs = findUnreturnedNeweggInputs(urls, rows);
    stats.skipped += unreturnedInputs.length;
    if (unreturnedInputs.length) {
      log("warn", "newegg_provider_inputs_unreturned", { runId, snapshotId, count: unreturnedInputs.length, urls: unreturnedInputs });
    }

    await mapLimit(rows, config.INGEST_CONCURRENCY, async raw => {
      const providerFailure = providerError(raw);
      if (providerFailure) {
        stats.skipped++;
        await deadLetter(platformId, runId, raw, providerFailure.code, providerFailure.message, false);
        return;
      }
      const parsed = NeweggRecordSchema.safeParse(raw);
      if (!parsed.success) {
        stats.failed++;
        await deadLetter(platformId, runId, raw, "VALIDATION_ERROR", parsed.error.message);
        await localDlq(raw, "VALIDATION_ERROR", parsed.error);
        return;
      }
      try {
        await ingestRecord(platformId, runId, parsed.data);
        stats.collected++;
      } catch (error) {
        stats.failed++;
        await deadLetter(platformId, runId, parsed.data, "INGEST_ERROR", String(error));
        await localDlq(parsed.data, "INGEST_ERROR", error);
      }
    });

    const status = stats.failed || stats.skipped ? "partial" : "completed";
    const reason = status === "partial" ? `${stats.skipped} provider inputs skipped; ${stats.failed} ingestion failures` : undefined;
    await finishRun(runId, status, stats, reason);
    log("info", "newegg_run_completed", { runId, ...stats, status });
  } catch (error) {
    if (runId) await finishRun(runId, "failed", stats, String(error));
    log("error", "newegg_run_failed", { runId, error: String(error), ...stats });
    throw error;
  } finally {
    await pool.end();
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
