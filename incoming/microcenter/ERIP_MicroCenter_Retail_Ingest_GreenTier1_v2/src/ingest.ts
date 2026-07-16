import type { AppConfig } from "./config.js";
import type { Database } from "./db.js";
import type { Logger } from "./logger.js";
import { normalizeMicroCenter } from "./normalizer.js";

export async function ingestRecords(args: {
  cfg: AppConfig; db: Database; log: Logger; runId: string; platformId: string;
  records: unknown[]; observedAt?: string;
}) {
  const observedAt = args.observedAt ?? new Date().toISOString();
  const normalized = [];
  const quality = [];

  for (let position = 0; position < args.records.length; position++) {
    const result = normalizeMicroCenter(args.records[position], observedAt);
    if (!result.ok) {
      quality.push({
        position, code: result.code, message: result.message,
        payload: args.records[position], severity: "error"
      });
      continue;
    }
    if (result.value.offer.evidence_confidence < args.cfg.INGEST_MIN_EVIDENCE_CONFIDENCE) {
      quality.push({
        position, code: "LOW_EVIDENCE_CONFIDENCE",
        message: `Evidence confidence ${result.value.offer.evidence_confidence} below minimum ${args.cfg.INGEST_MIN_EVIDENCE_CONFIDENCE}.`,
        payload: args.records[position], severity: "warning"
      });
      continue;
    }
    normalized.push({ position, value: result.value });
  }

  const result = await args.db.ingest({
    runId: args.runId, platformId: args.platformId, records: args.records,
    normalized, quality, observedAt
  });

  const quarantineRate = args.records.length ? result.quarantined / args.records.length : 0;
  const duplicateRate = normalized.length ? result.duplicates / normalized.length : 0;

  if (quarantineRate > args.cfg.INGEST_MAX_QUARANTINE_RATE) {
    throw new Error(`Quarantine rate ${quarantineRate.toFixed(4)} exceeds threshold ${args.cfg.INGEST_MAX_QUARANTINE_RATE}`);
  }
  if (duplicateRate > args.cfg.INGEST_MAX_DUPLICATE_RATE) {
    args.log.warn({ duplicate_rate: duplicateRate }, "duplicate_rate_exceeds_warning_threshold");
  }

  return { ...result, normalizedCount: normalized.length, quarantineRate, duplicateRate };
}
