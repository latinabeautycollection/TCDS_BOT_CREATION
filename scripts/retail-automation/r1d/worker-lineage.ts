type JsonRecord = Record<string, unknown>;

function asRecord(value: unknown): JsonRecord | null {
  return value !== null && typeof value === 'object'
    ? value as JsonRecord
    : null;
}

export function extractWorkerMetrics(stdout: string): JsonRecord {
  const lines = stdout.split(/\r?\n/).map(line => line.trim()).filter(Boolean);

  for (const line of lines.reverse()) {
    try {
      const parsed = asRecord(JSON.parse(line));
      if (!parsed) continue;

      const explicit = asRecord(parsed.r1d_metrics);
      if (explicit) return explicit;

      // Certified legacy runners already emit this terminal structured event.
      if (parsed.event === 'worker_complete' && typeof parsed.run_id === 'string') {
        return {
          collection_run_id: parsed.run_id,
          records_requested: parsed.total_rows,
          records_collected: parsed.collected,
          records_failed: parsed.failed
        };
      }
      // The certified Target package emits a Pino terminal event.
      if (
        parsed.msg === 'Target ingest completed' &&
        typeof parsed.runId === 'string'
      ) {
        const collected =
          typeof parsed.collected === 'number' ? parsed.collected : 0;
        const failed =
          typeof parsed.failed === 'number' ? parsed.failed : 0;
        const skipped =
          typeof parsed.skipped === 'number' ? parsed.skipped : 0;

        return {
          collection_run_id: parsed.runId,
          records_requested: collected + failed + skipped,
          records_collected: collected,
          records_failed: failed,
          records_skipped: skipped,
          records_recovered:
            typeof parsed.recovered === 'number' ? parsed.recovered : 0
        };
      }

    } catch {
      // Non-JSON application output is retained in stdout evidence but ignored here.
    }
  }

  return {};
}

export function requireCertificationCollectionRunId(metrics: JsonRecord): string {
  const value = metrics.collection_run_id;
  if (
    typeof value !== 'string' ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
  ) {
    throw new Error('Certification worker requires a valid collection_run_id metric');
  }
  return value;
}
