import fs from 'node:fs/promises';
import path from 'node:path';
import { config } from './config.js';
import { log } from './log.js';
import { triggerDataset, waitForSnapshot, downloadSnapshot } from './brightdata.js';
import { CDWRecordSchema } from './types.js';
import { platformAndConfig, createRun, finishRun, deadLetter, ingestRecord, saveEvidence, pool } from './db.js';
import { isCDWUrl, sha256, stableJson } from './util.js';
import { unlockCDWPage } from './unlocker.js';
import { discoverCDWProducts } from './discovery.js';

async function localDlq(payload: unknown, code: string, error: unknown) {
  await fs.mkdir(config.DLQ_DIRECTORY, { recursive: true });
  await fs.writeFile(
    path.join(config.DLQ_DIRECTORY, `${Date.now()}-${code}-${sha256(stableJson(payload)).slice(0, 12)}.json`),
    JSON.stringify({ ts: new Date().toISOString(), code, error: String(error), payload }, null, 2)
  );
}

async function mapLimit<T>(items: T[], limit: number, fn: (x: T) => Promise<void>) {
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (true) {
      const n = i++;
      if (n >= items.length) return;
      await fn(items[n]!);
    }
  }));
}

async function main() {
  const badUrl = config.seedUrls.find(u => !isCDWUrl(u));
  if (badUrl) throw new Error(`Rejected non-CDW seed URL: ${badUrl}`);

  const { platformId, configId } = await platformAndConfig();
  const runKey = `cdw:${new Date().toISOString().slice(0, 13)}:${sha256(config.seedUrls.join('|')).slice(0, 12)}`;
  let runId = '';
  const stats = { collected: 0, failed: 0, skipped: 0 };

  try {
    runId = await createRun(platformId, configId, runKey, config.seedUrls);
    log('info', 'cdw_run_started', { runId, seeds: config.seedUrls });

    const products = await discoverCDWProducts(
      config.seedUrls,
      async url => {
        const ev = await unlockCDWPage(url);
        await saveEvidence(platformId, runId, url, ev.zone, ev.body, ev.contentType, ev.status, {
          phase: 'category_discovery',
          page_not_found: ev.pageNotFound
        });
        return ev.body;
      },
      config.CDW_LIMIT_PER_INPUT
    );

    const urls = products.map(product => product.url);
    log('info', 'cdw_discovery_completed', {
      runId,
      seeds: config.seedUrls.length,
      discovered: urls.length,
      distinct: new Set(urls).size
    });

    await pool.query(
      `UPDATE retail.collection_runs
       SET total_requested = $2,
           run_metadata = run_metadata || $3::jsonb
       WHERE id = $1`,
      [
        runId,
        urls.length,
        JSON.stringify({
          category_seed_count: config.seedUrls.length,
          discovered_pdp_count: urls.length,
          detail_limit_per_input: config.CDW_DETAIL_LIMIT_PER_INPUT
        })
      ]
    );

    if (urls.length === 0) {
      stats.failed = config.seedUrls.length;
      await deadLetter(
        platformId,
        runId,
        { seed_urls: config.seedUrls },
        'DISCOVERY_EMPTY',
        'CDW category discovery returned no PDP URLs'
      );
      await finishRun(runId, 'failed', stats, 'CDW category discovery returned no PDP URLs');
      log('error', 'cdw_run_failed', { runId, ...stats, reason: 'discovery_empty' });
      return;
    }

    const snapshotId = await triggerDataset(urls);
    log('info', 'dataset_triggered', { runId, snapshotId, requested: urls.length });
    await waitForSnapshot(snapshotId);
    const rows = await downloadSnapshot(snapshotId);
    log('info', 'snapshot_downloaded', { runId, snapshotId, rows: rows.length });

    await mapLimit(rows, config.INGEST_CONCURRENCY, async raw => {
      if ((raw as any)?.error || (raw as any)?.error_code) {
        stats.skipped++;
        await deadLetter(
          platformId,
          runId,
          raw,
          `PROVIDER_${String((raw as any).error_code || 'unknown')}`,
          String((raw as any).error || 'Provider error')
        );
        return;
      }

      const p = CDWRecordSchema.safeParse(raw);
      if (!p.success) {
        stats.failed++;
        await deadLetter(platformId, runId, raw, 'VALIDATION_ERROR', p.error.message);
        await localDlq(raw, 'VALIDATION_ERROR', p.error);
        return;
      }

      try {
        await ingestRecord(platformId, runId, p.data);
        stats.collected++;
      } catch (e) {
        stats.failed++;
        await deadLetter(platformId, runId, p.data, 'INGEST_ERROR', String(e));
        await localDlq(p.data, 'INGEST_ERROR', e);
        if (config.CDW_UNLOCKER_MODE === 'fallback') {
          try {
            const ev = await unlockCDWPage(p.data.url);
            await saveEvidence(platformId, runId, p.data.url, ev.zone, ev.body, ev.contentType, ev.status, {
              phase: 'fallback',
              ingest_error: String(e),
              page_not_found: ev.pageNotFound
            });
          } catch (ue) {
            await deadLetter(platformId, runId, { url: p.data.url, original: p.data }, 'UNLOCKER_FALLBACK_ERROR', String(ue));
          }
        }
      }
    });

    const omitted = Math.max(0, urls.length - rows.length);
    if (omitted > 0) {
      stats.skipped += omitted;
      await deadLetter(
        platformId,
        runId,
        { requested_urls: urls.length, returned_rows: rows.length },
        'PROVIDER_SHORTFALL',
        `CDW dataset returned ${rows.length} rows for ${urls.length} requested PDP URLs`
      );
    }

    const status = stats.failed + stats.skipped === 0 ? 'completed' : 'partial';
    await finishRun(runId, status, stats, status === 'completed' ? undefined : `${stats.skipped} provider rows skipped; ${stats.failed} ingestion failures`);
    log('info', 'cdw_run_completed', { runId, snapshotId, requested: urls.length, returned: rows.length, ...stats, status });
  } catch (e) {
    if (runId) await finishRun(runId, 'failed', stats, String(e));
    log('error', 'cdw_run_failed', { runId, error: String(e), ...stats });
    throw e;
  } finally {
    await pool.end();
  }
}

main().catch(() => process.exitCode = 1);
