import { createHash } from "node:crypto";
import pg from "pg";
import { env } from "../config/env.js";

const { Pool } = pg;
type Counts = { collected: number; failed: number; skipped: number };

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function object(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" ? value as Record<string, unknown> : null;
}

function hash(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

export class CanonicalDatabase {
  readonly pool = new Pool({
    connectionString: env.DATABASE_URL,
    application_name: "tcds-adorama-brightdata-ingestion"
  });

  async close(): Promise<void> { await this.pool.end(); }

  async lock(): Promise<boolean> {
    const result = await this.pool.query(
      "select pg_try_advisory_lock(hashtextextended($1,0)) locked",
      ["adorama:category-ingest"]
    );
    return Boolean(result.rows[0]?.locked);
  }

  async unlock(): Promise<void> {
    await this.pool.query(
      "select pg_advisory_unlock(hashtextextended($1,0))",
      ["adorama:category-ingest"]
    );
  }

  async startRun(requested: number, metadata: Record<string, unknown>): Promise<string> {
    const result = await this.pool.query(`
      select retail.start_collection_run(
        'adorama',
        'brightdata_adorama_category_v1',
        'adorama-category-worker',
        'category_discovery_to_pdp',
        $1::jsonb
      ) as run_id
    `, [JSON.stringify({ ...metadata, requested_rows: requested })]);
    return result.rows[0].run_id as string;
  }

  async ingest(runId: string, rows: unknown[], snapshotId: string): Promise<Counts> {
    const platform = await this.pool.query(
      "select id from retail.retail_platforms where platform_code='adorama'"
    );
    const platformId = platform.rows[0]?.id as string | undefined;
    if (!platformId) throw new Error("Adorama platform is not registered; apply migration 026 first");

    const counts: Counts = { collected: 0, failed: 0, skipped: 0 };
    for (const raw of rows) {
      const row = object(raw);
      if (!row) {
        counts.failed++;
        await this.deadLetter(platformId, runId, raw, "INVALID_ROW", "Snapshot row is not an object", "pending");
        continue;
      }

      if (row.error || row.error_code) {
        counts.skipped++;
        await this.deadLetter(
          platformId, runId, row,
          `PROVIDER_${text(row.error_code) ?? "unknown"}`,
          text(row.error) ?? "Bright Data provider error",
          "abandoned"
        );
        continue;
      }

      const input = object(row.input);
      const url = text(row.url) ?? text(input?.url);
      const key = text(row.variant_id) ?? text(row.item_id) ?? url;
      if (!key || !url || !text(row.title)) {
        counts.failed++;
        await this.deadLetter(platformId, runId, row, "INCOMPLETE_PRODUCT", "Missing product key, URL, or title", "pending");
        continue;
      }

      const client = await this.pool.connect();
      try {
        await client.query("begin");
        const capture = await client.query(`
          select retail.ingest_raw_product_capture(
            'adorama', $1::uuid, $2::text, $3::text,
            $4::text, $5::text, $6::text, $7::jsonb,
            'brightdata_adorama_v1', $8::jsonb
          ) as id
        `, [
          runId, key, url, text(row.title), text(row.brand), text(row.product_category),
          JSON.stringify(row), JSON.stringify({ source: "brightdata", snapshot_id: snapshotId })
        ]);
        const parsed = await client.query(
          "select retail.ingest_brightdata_adorama_product($1::uuid,$2::jsonb) as id",
          [capture.rows[0].id, JSON.stringify(row)]
        );
        await client.query(
          "select retail.promote_adorama_parsed_product($1::uuid)",
          [parsed.rows[0].id]
        );
        await client.query("commit");
        counts.collected++;
      } catch (error) {
        await client.query("rollback");
        counts.failed++;
        await this.deadLetter(
          platformId, runId, row, "ADORAMA_INGEST_FAILED",
          error instanceof Error ? error.message : String(error), "pending"
        );
      } finally {
        client.release();
      }
    }
    return counts;
  }

  async complete(runId: string, requested: number, counts: Counts, metadata: Record<string, unknown>): Promise<void> {
    const status = counts.failed > 0 || counts.skipped > 0 ? "partial" : "completed";
    const reason = status === "partial"
      ? `${counts.skipped} provider rows skipped; ${counts.failed} ingestion rows failed`
      : null;
    await this.pool.query(`
      call retail.complete_collection_run(
        $1::uuid,$2::retail.collection_status,$3::int,$4::int,
        $5::int,$6::int,$7::text,$8::jsonb
      )
    `, [runId, status, requested, counts.collected, counts.failed, counts.skipped, reason, JSON.stringify(metadata)]);
  }

  private async deadLetter(
    platformId: string,
    runId: string,
    raw: unknown,
    code: string,
    message: string,
    status: "pending" | "abandoned"
  ): Promise<void> {
    await this.pool.query(`
      insert into retail.ingest_dead_letters(
        platform_id,collection_run_id,source_platform,payload_hash,
        raw_payload,error_code,error_message,status,next_retry_at,resolution_notes
      ) values($1::uuid,$2::uuid,'adorama',$3,$4::jsonb,$5,$6,$7,null,$8)
      on conflict(source_platform,payload_hash) do update set
        collection_run_id=excluded.collection_run_id,
        error_code=excluded.error_code,
        error_message=excluded.error_message,
        status=excluded.status,
        last_failed_at=now(),
        attempt_count=retail.ingest_dead_letters.attempt_count+1,
        next_retry_at=null,
        resolution_notes=excluded.resolution_notes
    `, [
      platformId, runId, hash(raw), JSON.stringify(raw), code, message, status,
      status === "abandoned" ? "Provider error retained without automatic retry" : null
    ]);
  }
}
