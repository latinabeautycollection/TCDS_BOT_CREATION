import pg from "pg";
import type { AppConfig } from "./config.js";
import type { Logger } from "./logger.js";
import { chunk, sha256, uuid } from "./util.js";
import type { Normalized } from "./normalizer.js";

const { Pool } = pg;

export class Database {
  readonly pool: pg.Pool;
  constructor(private readonly cfg: AppConfig, private readonly log: Logger) {
    this.pool = new Pool({
      connectionString: cfg.DATABASE_URL,
      max: cfg.DATABASE_POOL_MAX,
      ssl: cfg.DATABASE_SSL ? { rejectUnauthorized: false } : undefined,
      statement_timeout: cfg.DATABASE_STATEMENT_TIMEOUT_MS,
      lock_timeout: cfg.DATABASE_LOCK_TIMEOUT_MS,
      application_name: "erip-microcenter-retail-ingest"
    });
    this.pool.on("error", error => this.log.error({ error: error.message }, "postgres_pool_error"));
  }

  async close() { await this.pool.end(); }
  private table(name: string) { return `"${this.cfg.RETAIL_SCHEMA}"."${name}"`; }

  async health() {
    const r = await this.pool.query("select now() as now, current_database() as database");
    return r.rows[0];
  }

  async platformId(): Promise<string> {
    const q = `
      insert into ${this.table("platforms")}(platform_code, platform_name)
      values ($1,$2)
      on conflict(platform_code) do update set platform_name=excluded.platform_name, updated_at=now()
      returning platform_id`;
    const r = await this.pool.query(q, [this.cfg.RETAIL_PLATFORM_CODE, this.cfg.RETAIL_SOURCE_NAME]);
    return r.rows[0].platform_id as string;
  }

  async acquireAdvisoryLock(lockKey: string): Promise<boolean> {
    const key = BigInt("0x" + sha256(lockKey).slice(0, 15));
    const r = await this.pool.query("select pg_try_advisory_lock($1::bigint) as locked", [key.toString()]);
    return Boolean(r.rows[0].locked);
  }

  async releaseAdvisoryLock(lockKey: string): Promise<void> {
    const key = BigInt("0x" + sha256(lockKey).slice(0, 15));
    await this.pool.query("select pg_advisory_unlock($1::bigint)", [key.toString()]);
  }

  async createRun(args: {
    runId: string; platformId: string; runKey: string; status: string;
    inputCount: number; payload: unknown;
  }) {
    await this.pool.query(`
      insert into ${this.table("collection_runs")}
      (collection_run_id, platform_id, dataset_id, run_key, status, requested_input_count,
       request_payload, worker_id, environment)
      values ($1,$2,$3,$4,$5,$6,$7::jsonb,$8,$9)`,
      [args.runId, args.platformId, this.cfg.BRIGHT_DATA_DATASET_ID, args.runKey,
       args.status, args.inputCount, JSON.stringify(args.payload),
       this.cfg.ERIP_WORKER_ID, this.cfg.ERIP_ENVIRONMENT]);
  }

  async updateRun(runId: string, patch: Record<string, unknown>) {
    const keys = Object.keys(patch);
    if (!keys.length) return;
    const values = keys.map(k => patch[k]);
    const sets = keys.map((k,i) => `"${k}"=$${i+2}`).join(",");
    await this.pool.query(
      `update ${this.table("collection_runs")} set ${sets}, updated_at=now() where collection_run_id=$1`,
      [runId, ...values.map(v => typeof v === "object" && v !== null ? JSON.stringify(v) : v)]
    );
  }

  async ingest(args: {
    runId: string; platformId: string; records: unknown[];
    normalized: Array<{position:number; value:Normalized}>;
    quality: Array<{position:number; code:string; message:string; payload:unknown; severity:string}>;
    observedAt: string;
  }): Promise<{rawInserted:number; offersInserted:number; duplicates:number; quarantined:number}> {
    const client = await this.pool.connect();
    try {
      await client.query("begin");
      let rawInserted = 0;
      let offersInserted = 0;
      let duplicates = 0;

      if (this.cfg.INGEST_STORE_RAW) {
        for (const batch of chunk(args.records.map((payload, position) => ({
          id: uuid(), position, payload, hash: sha256(payload),
          url: extractUrl(payload)
        })), this.cfg.INGEST_BATCH_SIZE)) {
          for (const row of batch) {
            const r = await client.query(`
              insert into ${this.table("raw_product_captures")}
              (raw_capture_id, collection_run_id, platform_id, source_record_hash, source_position,
               source_url, payload, observed_at)
              values ($1,$2,$3,$4,$5,$6,$7::jsonb,$8)
              on conflict(platform_id, source_record_hash) do nothing`,
              [row.id,args.runId,args.platformId,row.hash,row.position,row.url,JSON.stringify(row.payload),args.observedAt]);
            rawInserted += r.rowCount ?? 0;
          }
        }
      }

      for (const item of args.normalized) {
        const p = item.value.product;
        const existing = await client.query(`
          insert into ${this.table("retail_products")}
          (retail_product_id, platform_id, retailer_product_key, retailer_sku, upc, gtin, mpn,
           brand, model, title, product_url, image_url, category_text, condition_text, seller_name,
           identity_confidence, first_seen_at, last_seen_at, latest_payload)
          values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$17,$18::jsonb)
          on conflict(platform_id, retailer_product_key) do update set
            retailer_sku=coalesce(excluded.retailer_sku, retail.retail_products.retailer_sku),
            upc=coalesce(excluded.upc, retail.retail_products.upc),
            gtin=coalesce(excluded.gtin, retail.retail_products.gtin),
            mpn=coalesce(excluded.mpn, retail.retail_products.mpn),
            brand=coalesce(excluded.brand, retail.retail_products.brand),
            model=coalesce(excluded.model, retail.retail_products.model),
            title=excluded.title,
            product_url=coalesce(excluded.product_url, retail.retail_products.product_url),
            image_url=coalesce(excluded.image_url, retail.retail_products.image_url),
            category_text=coalesce(excluded.category_text, retail.retail_products.category_text),
            condition_text=coalesce(excluded.condition_text, retail.retail_products.condition_text),
            seller_name=coalesce(excluded.seller_name, retail.retail_products.seller_name),
            identity_confidence=greatest(retail.retail_products.identity_confidence, excluded.identity_confidence),
            last_seen_at=excluded.last_seen_at,
            latest_payload=excluded.latest_payload,
            updated_at=now()
          returning retail_product_id`,
          [p.retail_product_id,args.platformId,p.retailer_product_key,p.retailer_sku,p.upc,p.gtin,p.mpn,
           p.brand,p.model,p.title,p.product_url,p.image_url,p.category_text,p.condition_text,p.seller_name,
           p.identity_confidence,args.observedAt,JSON.stringify(p.latest_payload)]);
        const productId = existing.rows[0].retail_product_id as string;
        const o = item.value.offer;
        const offer = await client.query(`
          insert into ${this.table("retail_offer_snapshots")}
          (retail_offer_snapshot_id, collection_run_id, platform_id, retail_product_id,
           source_record_hash, currency_code, current_price, original_price, shipping_cost,
           in_stock, stock_text, store_id, store_name, rating, review_count, evidence_confidence,
           observed_at, payload)
          values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18::jsonb)
          on conflict(platform_id, source_record_hash) do nothing
          returning retail_offer_snapshot_id`,
          [o.retail_offer_snapshot_id,args.runId,args.platformId,productId,o.source_record_hash,
           o.currency_code,o.current_price,o.original_price,o.shipping_cost,o.in_stock,o.stock_text,
           o.store_id,o.store_name,o.rating,o.review_count,o.evidence_confidence,o.observed_at,
           JSON.stringify(o.payload)]);
        if (!offer.rowCount) { duplicates++; continue; }
        offersInserted++;
        const offerId = offer.rows[0].retail_offer_snapshot_id as string;
        await client.query(`
          insert into ${this.table("product_price_history")}
          (price_history_id, platform_id, retail_product_id, retail_offer_snapshot_id,
           currency_code, current_price, original_price, shipping_cost, observed_at)
          values ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
          [uuid(),args.platformId,productId,offerId,o.currency_code,o.current_price,o.original_price,o.shipping_cost,o.observed_at]);
        await client.query(`
          insert into ${this.table("product_inventory_history")}
          (inventory_history_id, platform_id, retail_product_id, retail_offer_snapshot_id,
           in_stock, stock_text, store_id, store_name, observed_at)
          values ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
          [uuid(),args.platformId,productId,offerId,o.in_stock,o.stock_text,o.store_id,o.store_name,o.observed_at]);
      }

      for (const q of args.quality) {
        await client.query(`
          insert into ${this.table("data_quality_events")}
          (data_quality_event_id, collection_run_id, platform_id, source_position,
           severity, event_code, event_message, payload)
          values ($1,$2,$3,$4,$5,$6,$7,$8::jsonb)`,
          [uuid(),args.runId,args.platformId,q.position,q.severity,q.code,q.message,JSON.stringify(q.payload)]);
      }

      await client.query("commit");
      return { rawInserted, offersInserted, duplicates, quarantined: args.quality.length };
    } catch (e) {
      await client.query("rollback");
      throw e;
    } finally {
      client.release();
    }
  }
}

function extractUrl(value: unknown): string | null {
  if (!value || typeof value !== "object") return null;
  const o = value as Record<string, unknown>;
  for (const key of ["url","product_url","link","product_link"]) {
    if (typeof o[key] === "string") return o[key] as string;
  }
  return null;
}
