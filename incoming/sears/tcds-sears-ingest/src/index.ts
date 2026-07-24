import fs from 'node:fs/promises';
import path from 'node:path';
import { config } from './config.js';
import { log } from './log.js';
import {
  platformAndConfig,
  createRun,
  resumeRun,
  getRunProgress,
  updateRunRequestTotal,
  finishRun,
  deadLetter,
  ingestRecord,
  pool
} from './db.js';
import { discoverSearsProducts } from './discovery.js';
import { unlockSearsPage } from './unlocker.js';
import { parseSearsPdp } from './parser.js';
import { SEARSRecordSchema } from './types.js';
import { sha256, stableJson } from './util.js';

async function localDlq(payload: unknown, code: string, error: unknown) {
  await fs.mkdir(config.DLQ_DIRECTORY, { recursive: true });
  await fs.writeFile(
    path.join(
      config.DLQ_DIRECTORY,
      `${Date.now()}-${code}-${sha256(stableJson(payload)).slice(0, 12)}.json`
    ),
    JSON.stringify({ ts: new Date().toISOString(), code, error: String(error), payload }, null, 2)
  );
}

async function main() {
  const { platformId, configId } = await platformAndConfig();
  const discovered = await discoverSearsProducts(
    config.SEARS_SITEMAP_INDEX_URL,
    config.sitemapCategories,
    config.SEARS_DISCOVERY_LIMIT
  );
  if (!discovered.length) throw new Error('Sears sitemap discovery returned no PDP URLs');

  const runKey = `sears:${new Date().toISOString()}:${sha256(discovered.join('|')).slice(0, 12)}`;
  let runId = '';
  const stats = { collected: 0, failed: 0, skipped: 0 };
  let attempted = 0;
  let cursor = 0;

  try {
    const previous = config.SEARS_RUN_ID
      ? await resumeRun(config.SEARS_RUN_ID, platformId)
      : null;
    runId = config.SEARS_RUN_ID ??
      await createRun(platformId, configId, runKey, discovered);
    stats.collected = previous?.collected ?? 0;
    stats.skipped = previous?.skipped ?? 0;
    const candidates = previous
      ? discovered.filter(url => !previous.attemptedUrls.has(url))
      : discovered;
    log('info', 'sears_run_started', {
      runId,
      discovered: discovered.length,
      remainingCandidates: candidates.length,
      resumed: Boolean(previous),
      startingCollected: stats.collected,
      target: config.SEARS_QA_TARGET,
      categories: config.sitemapCategories
    });

    const worker = async () => {
      while (stats.collected < config.SEARS_QA_TARGET) {
        const position = cursor++;
        if (position >= candidates.length) return;
        const url = candidates[position]!;
        attempted++;
        try {
          const unlocked = await unlockSearsPage(url);
          const parsed = SEARSRecordSchema.parse(parseSearsPdp(unlocked.body, url));
          await ingestRecord(platformId, runId, parsed);
          stats.collected++;
          log('info', 'sears_product_collected', {
            runId,
            itemId: parsed.item_id,
            collected: stats.collected,
            target: config.SEARS_QA_TARGET
          });
        } catch (error) {
          stats.skipped++;
          await deadLetter(
            platformId,
            runId,
            { input: { url } },
            'SEARS_PDP_RECOVERY_ERROR',
            String(error)
          );
          await localDlq({ input: { url } }, 'SEARS_PDP_RECOVERY_ERROR', error);
          log('warn', 'sears_product_skipped', { runId, url, error: String(error) });
        }
      }
    };

    await Promise.all(
      Array.from(
        { length: Math.min(config.INGEST_CONCURRENCY, candidates.length) },
        worker
      )
    );

    const finalProgress = await getRunProgress(runId);
    stats.collected = finalProgress.collected;
    stats.skipped = finalProgress.skipped;
    attempted = finalProgress.attemptedUrls.size;
    await updateRunRequestTotal(runId, attempted, {
      discovered: discovered.length,
      target: config.SEARS_QA_TARGET,
      sitemap_index: config.SEARS_SITEMAP_INDEX_URL,
      sitemap_categories: config.sitemapCategories
    });

    const targetReached = stats.collected >= config.SEARS_QA_TARGET;
    const status = targetReached && stats.skipped === 0 ? 'completed' : 'partial';
    const reason = status === 'partial'
      ? `${stats.skipped} sitemap PDPs skipped; ${stats.collected}/${config.SEARS_QA_TARGET} target collected`
      : undefined;

    await finishRun(runId, status, stats, reason);
    log('info', 'sears_run_completed', {
      runId,
      status,
      attempted,
      discovered: discovered.length,
      target: config.SEARS_QA_TARGET,
      ...stats
    });
  } catch (error) {
    if (runId) await finishRun(runId, 'failed', stats, String(error));
    log('error', 'sears_run_failed', { runId, error: String(error), ...stats });
    throw error;
  } finally {
    await pool.end();
  }
}

main().catch(error => {
  log('error', 'sears_fatal_error', { error: String(error) });
  process.exitCode = 1;
});
