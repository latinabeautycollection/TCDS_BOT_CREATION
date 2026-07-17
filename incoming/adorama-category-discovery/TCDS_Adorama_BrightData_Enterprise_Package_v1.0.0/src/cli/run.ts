import { env } from "../config/env.js";
import { logger } from "../infra/logger.js";
import { BrightDataClient } from "../services/brightDataClient.js";
import { CanonicalDatabase } from "../services/canonicalDatabase.js";
import { discoverAdoramaInputs } from "../services/discovery.js";

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

async function wait(bright: BrightDataClient, snapshotId: string): Promise<void> {
  for (let attempt = 1; attempt <= env.POLL_MAX_ATTEMPTS; attempt++) {
    const progress = await bright.progress(snapshotId);
    const status = String(progress.status ?? "").toLowerCase();
    logger.info({ snapshotId, attempt, status }, "Adorama snapshot progress");
    if (["ready", "done", "completed", "success"].includes(status)) return;
    if (["failed", "error", "cancelled", "canceled"].includes(status)) {
      throw new Error(`Bright Data snapshot failed: ${JSON.stringify(progress)}`);
    }
    await sleep(env.POLL_INTERVAL_MS);
  }
  throw new Error(`Timed out waiting for Adorama snapshot after ${env.POLL_MAX_ATTEMPTS} polls`);
}

async function main(): Promise<void> {
  const bright = new BrightDataClient();
  const db = new CanonicalDatabase();
  let locked = false;
  try {
    locked = await db.lock();
    if (!locked) throw new Error("Another Adorama ingest is already running");

    const inputs = await discoverAdoramaInputs(
      env.inputUrls,
      url => bright.fetchUnlockedHtml(url),
      env.ADORAMA_LIMIT_PER_INPUT
    );
    logger.info({ seedCount: env.inputUrls.length, discovered: inputs.length }, "Adorama discovery completed");
    const snapshotId = await bright.trigger(inputs, 1);
    await wait(bright, snapshotId);
    const rows = await bright.download(snapshotId);
    const runId = await db.startRun(inputs.length, {
      source: "brightdata",
      dataset_id: env.BRIGHTDATA_DATASET_ID,
      snapshot_id: snapshotId,
      mode: "category_discovery_to_pdp",
      provider_error_retry_limit: 0
    });
    const counts = await db.ingest(runId, rows, snapshotId);
    await db.complete(runId, rows.length, counts, { snapshot_id: snapshotId, discovered: inputs.length });
    logger.info({ runId, snapshotId, totalRows: rows.length, ...counts }, "Adorama ingest completed");
  } finally {
    if (locked) await db.unlock().catch(() => undefined);
    await db.close();
  }
}

main().catch(error => {
  logger.fatal({ err: error }, "Adorama ingest failed");
  process.exitCode = 1;
});
