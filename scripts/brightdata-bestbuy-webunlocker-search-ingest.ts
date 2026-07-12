import { Pool, PoolClient } from "pg";
import crypto from "crypto";
import http from "http";
const ENV = {
  BRIGHTDATA_TOKEN: process.env.BRIGHTDATA_TOKEN,
  DATABASE_URL: process.env.DATABASE_URL,
  BRIGHTDATA_WEB_UNLOCKER_ZONE: process.env.BRIGHTDATA_WEB_UNLOCKER_ZONE,
  DATASET_ID: process.env.BESTBUY_DATASET_ID ?? "gd_ltre1jqe1jfr7cccf",
  BASE_URL: process.env.BRIGHTDATA_BASE_URL ?? "https://api.brightdata.com",
  MAX_RETRIES: Number(process.env.BESTBUY_MAX_RETRIES ?? 5),
  HTTP_TIMEOUT_MS: Number(process.env.BESTBUY_HTTP_TIMEOUT_MS ?? 45_000),
  POLL_INTERVAL_MS: Number(process.env.BESTBUY_POLL_INTERVAL_MS ?? 15_000),
  MAX_POLLS: Number(process.env.BESTBUY_MAX_POLLS ?? 180),
  CONCURRENCY: Number(process.env.BESTBUY_CONCURRENCY ?? 5),
  MAX_ROWS: Number(process.env.BESTBUY_MAX_ROWS ?? 0),
  RATE_LIMIT_PER_MINUTE: Number(process.env.BESTBUY_RATE_LIMIT_PER_MINUTE ?? 30),
  HEALTH_PORT: Number(process.env.BESTBUY_HEALTH_PORT ?? 8097),
  PROMOTE_SYNC: process.env.BESTBUY_PROMOTE_SYNC !== "false",
  RETRY_TIMEOUT_ROWS: process.env.BESTBUY_RETRY_TIMEOUT_ROWS === "true",
};
const LOCK_KEY = 913_880_221;
const payload = {
  input: [
    {
      url: "https://www.bestbuy.com/site/searchpage.jsp?browsedCategory=pcmcat1632941704767&id=pcat17071&qp=currentoffers_facet%3DCurrent+Deals%7ETop+Deal%5Ecurrentoffers_facet%3DCurrent+Deals%7EClearance%5Ecurrentoffers_facet%3DCurrent+Deals%7EPackage+Deals%5Ecurrentprice_facet%3DPrice%7E1+to+500%5Esystemmemoryram_facet%3DSystem+Memory+%28RAM%29%7E32+gigabytes%5Esystemmemoryram_facet%3DSystem+Memory+%28RAM%29%7E64+gigabytes%5Esystemmemoryram_facet%3DSystem+Memory+%28RAM%29%7E24+gigabytes%5Esystemmemoryram_facet%3DSystem+Memory+%28RAM%29%7E16+gigabytes&st=pcmcat1632941704767_categoryid%24abcat0500000",
    },
    {
      url: "https://www.bestbuy.com/site/searchpage.jsp?browsedCategory=pcmcat1720706915460&id=pcat17071&qp=currentoffers_facet%3DCurrent+Deals%7EClearance%5Ecurrentoffers_facet%3DCurrent+Deals%7EPackage+Deals%5Ecurrentoffers_facet%3DCurrent+Deals%7ETop+Deal%5Ecurrentoffers_facet%3DCurrent+Deals%7EPlus+%26+Total+Member+Deals%5Ecurrentprice_facet%3DPrice%7E1+to+500%5Epercentdiscount_facet%3DDiscount%7EAll+Discounted+Items&st=pcmcat1720706915460_categoryid%24abcat0204000",
    },
  ],
  limit_per_input: Number(process.env.BESTBUY_LIMIT_PER_INPUT ?? 2000),
};
type RunStatus = "completed" | "partial" | "failed";
type DeadLetterClass =
  | "API_FAILURE"
  | "VALIDATION_FAILURE"
  | "DB_FAILURE"
  | "PROMOTION_FAILURE"
  | "SNAPSHOT_FAILURE"
  | "CIRCUIT_OPEN"
  | "UNKNOWN_FAILURE";
type BrightDataTriggerResponse = { snapshot_id?: string };
type BrightDataProgressResponse = { snapshot_id?: string; status?: string; records?: number; errors?: number };
type BestBuyRow = {
  url?: string;
  product_url?: string;
  product_id?: string;
  sku?: string;
  skuId?: string;
  sku_id?: string;
  id?: string;
  title?: string;
  product_name?: string;
  name?: string;
  short_description?: string;
  brand?: string;
  product_category?: string;
  root_category?: string;
  category_path?: string;
  breadcrumb_text?: string;
  images?: unknown;
  breadcrumbs?: unknown;
  product_specifications?: unknown;
  currency?: string;
  final_price?: unknown;
  sale_price?: unknown;
  offer_price?: unknown;
  initial_price?: unknown;
  error?: unknown;
  error_code?: string;
  [key: string]: unknown;
};
type Metrics = {
  startedAt: number;
  stage: string;
  runId?: string;
  snapshotId?: string;
  triggerMs: number;
  pollMs: number;
  downloadMs: number;
  ingestMs: number;
  totalRows: number;
  processed: number;
  collected: number;
  failed: number;
  skipped: number;
  deadLetters: number;
  retries: number;
  circuitOpenCount: number;
};
const metrics: Metrics = {
  startedAt: Date.now(),
  stage: "boot",
  triggerMs: 0,
  pollMs: 0,
  downloadMs: 0,
  ingestMs: 0,
  totalRows: 0,
  processed: 0,
  collected: 0,
  failed: 0,
  skipped: 0,
  deadLetters: 0,
  retries: 0,
  circuitOpenCount: 0,
};
const pool = new Pool({
  connectionString: ENV.DATABASE_URL,
  max: Math.max(ENV.CONCURRENCY + 4, 12),
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
});
let shutdownRequested = false;
function parseKeywordInput(raw: string | undefined): string[] {
  if (!raw || !raw.trim()) return [];

  const trimmed = raw.trim();

  if (trimmed.startsWith("[")) {
    const parsed = JSON.parse(trimmed);
    if (!Array.isArray(parsed)) throw new Error("BESTBUY_KEYWORDS JSON must be an array");
    return parsed.map((item) => String(item).trim()).filter(Boolean);
  }

  return trimmed
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function buildBestBuySearchUrl(keyword: string): string {
  const url = new URL("https://www.bestbuy.com/site/searchpage.jsp");
  url.searchParams.set("st", keyword);
  return url.toString();
}

function getConfiguredInputUrls(): string[] {
  const keywords = parseKeywordInput(process.env.BESTBUY_KEYWORDS);

  if (keywords.length > 0) {
    return keywords.map(buildBestBuySearchUrl);
  }

  return payload.input.map((item) => item.url);
}


function assertEnv(hasSearchUrls: boolean): void {
  if (!ENV.BRIGHTDATA_TOKEN) throw new Error("Missing BRIGHTDATA_TOKEN");
  if (!ENV.DATABASE_URL) throw new Error("Missing DATABASE_URL");
  if (hasSearchUrls && !ENV.BRIGHTDATA_WEB_UNLOCKER_ZONE) {
    throw new Error(
      "Missing BRIGHTDATA_WEB_UNLOCKER_ZONE environment variable. This is required to crawl search/category pages using the Web Unlocker."
    );
  }
  if (ENV.CONCURRENCY < 1 || ENV.CONCURRENCY > 10) {
    throw new Error("BESTBUY_CONCURRENCY must be between 1 and 10");
  }
}
function log(event: string, data: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({
    ts: new Date().toISOString(),
    service: "brightdata_bestbuy_search_ingest",
    worker_id: process.env.HOSTNAME ?? "local-worker",
    run_id: metrics.runId ?? null,
    snapshot_id: metrics.snapshotId ?? null,
    stage: metrics.stage,
    event,
    ...data,
  }));
}
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
function stableHash(value: unknown): string {
  return crypto.createHash("sha256").update(JSON.stringify(value)).digest("hex");
}
function normalizeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
function classifyError(error: unknown): DeadLetterClass {
  const message = normalizeError(error).toLowerCase();
  if (message.includes("circuit")) return "CIRCUIT_OPEN";
  if (message.includes("bright data") || message.includes("http")) return "API_FAILURE";
  if (message.includes("snapshot")) return "SNAPSHOT_FAILURE";
  if (message.includes("validation")) return "VALIDATION_FAILURE";
  if (message.includes("promotion")) return "PROMOTION_FAILURE";
  if (message.includes("postgres") || message.includes("sql") || message.includes("database")) return "DB_FAILURE";
  return "UNKNOWN_FAILURE";
}
function parseMoney(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  const cleaned = String(value).replace(/[^0-9.-]/g, "");
  if (!cleaned) return null;
  const parsed = Number(cleaned);
  return Number.isFinite(parsed) ? parsed : null;
}
function isArrayLike(value: unknown): boolean {
  return Array.isArray(value) || value === null || value === undefined;
}
function isSearchOrCategoryUrl(url: string): boolean {
  const u = url.toLowerCase();
  return (
    u.includes("searchpage.jsp") ||
    u.includes("/pcmcat") ||
    u.includes("st=") ||
    u.includes("/site/electronics/")
  );
}
function getPaginatedUrl(baseUrl: string, page: number): string {
  if (page === 1) return baseUrl;
  try {
    const parsedUrl = new URL(baseUrl);
    if (baseUrl.includes("searchpage.jsp") || parsedUrl.searchParams.has("st")) {
      parsedUrl.searchParams.set("cp", String(page));
    } else {
      parsedUrl.searchParams.set("page", String(page));
    }
    return parsedUrl.toString();
  } catch {
    const separator = baseUrl.includes("?") ? "&" : "?";
    const param = baseUrl.includes("searchpage.jsp") ? "cp" : "page";
    return `${baseUrl}${separator}${param}=${page}`;
  }
}
function extractProductUrlsFromHtml(html: string): string[] {
  const urls = new Set<string>();

  function addUrl(rawUrl: string, sku?: string): void {
    let cleanUrl = rawUrl
      .replace(/&amp;/g, "&")
      .replace(/\\u002F/g, "/")
      .trim();

    if (cleanUrl.startsWith("//")) {
      cleanUrl = `https:${cleanUrl}`;
    } else if (cleanUrl.startsWith("/")) {
      cleanUrl = `https://www.bestbuy.com${cleanUrl}`;
    } else if (!cleanUrl.startsWith("http")) {
      cleanUrl = `https://www.bestbuy.com/${cleanUrl}`;
    }

    if (sku && cleanUrl.includes("/site/") && cleanUrl.includes(".p") && !cleanUrl.includes("skuId=")) {
      cleanUrl += `${cleanUrl.includes("?") ? "&" : "?"}skuId=${sku}`;
    }

    urls.add(cleanUrl);
  }

  let match: RegExpExecArray | null;

  const modernProductRegex = /(?:https?:\/\/www\.bestbuy\.com)?\/product\/[^"\'<>{}\s]+\/[^"\'<>{}\s]+\/sku\/(\d+)/gi;
  while ((match = modernProductRegex.exec(html)) !== null) {
    addUrl(match[0], match[1]);
  }

  const escapedModernProductRegex = /(?:https?:\\u002F\\u002Fwww\.bestbuy\.com)?\\u002Fproduct\\u002F[^"\'<>\s]+\\u002F[^"\'<>\s]+\\u002Fsku\\u002F(\d+)/gi;
  while ((match = escapedModernProductRegex.exec(html)) !== null) {
    addUrl(match[0], match[1]);
  }

  const siteProductRegex = /(?:https?:\/\/www\.bestbuy\.com)?\/site\/[^"\'<>{}\s]*\/(\d+)\.p(?:\?[^"\'<>{}\s]*)?/gi;
  while ((match = siteProductRegex.exec(html)) !== null) {
    addUrl(match[0], match[1]);
  }

  return Array.from(urls);
}

function isBrightDataErrorRow(row: BestBuyRow): boolean {
  return Boolean(row?.error || row?.error_code);
}

function isRetryableBrightDataErrorRow(row: BestBuyRow): boolean {
  return String(row?.error_code || "").toLowerCase() === "wait_element_timeout";
}

function getBrightDataInputUrl(row: BestBuyRow): string | null {
  const input = row.input as { url?: unknown } | undefined;
  const url = input?.url || row.url || row.product_url;
  return url ? String(url) : null;
}

function orderRowsForProcessing(rows: BestBuyRow[]): BestBuyRow[] {
  return [...rows].sort((a, b) => Number(isBrightDataErrorRow(a)) - Number(isBrightDataErrorRow(b)));
}


class TokenBucket {
  private tokens: number;
  private lastRefill: number;
  constructor(private readonly capacity: number, private readonly refillPerMinute: number) {
    this.tokens = capacity;
    this.lastRefill = Date.now();
  }
  async take(): Promise<void> {
    while (true) {
      this.refill();
      if (this.tokens >= 1) {
        this.tokens -= 1;
        return;
      }
      await sleep(500);
    }
  }
  private refill(): void {
    const now = Date.now();
    const elapsedMinutes = (now - this.lastRefill) / 60_000;
    const refill = elapsedMinutes * this.refillPerMinute;
    if (refill >= 1) {
      this.tokens = Math.min(this.capacity, this.tokens + refill);
      this.lastRefill = now;
    }
  }
}
class CircuitBreaker {
  private failures = 0;
  private openedUntil = 0;
  constructor(private readonly maxFailures = 5, private readonly openMs = 120_000) {}
  beforeRequest(): void {
    if (Date.now() < this.openedUntil) {
      metrics.circuitOpenCount++;
      throw new Error("Circuit open for Bright Data API");
    }
  }
  success(): void {
    this.failures = 0;
    this.openedUntil = 0;
  }
  failure(): void {
    this.failures++;
    if (this.failures >= this.maxFailures) {
      this.openedUntil = Date.now() + this.openMs;
      log("circuit_opened", { open_ms: this.openMs, failures: this.failures });
    }
  }
}
class DatabaseExecutor {
  constructor(private readonly poolRef: Pool) {}
  async withClient<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.poolRef.connect();
    try {
      return await fn(client);
    } finally {
      client.release();
    }
  }
  async tx<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
    return this.withClient(async (client) => {
      await client.query("begin");
      try {
        const result = await fn(client);
        await client.query("commit");
        return result;
      } catch (error) {
        await client.query("rollback");
        throw error;
      }
    });
  }
}
class BrightDataClient {
  private readonly bucket = new TokenBucket(ENV.RATE_LIMIT_PER_MINUTE, ENV.RATE_LIMIT_PER_MINUTE);
  private readonly breaker = new CircuitBreaker();
  async fetchJson<T>(url: string, options: RequestInit, retries = ENV.MAX_RETRIES): Promise<T> {
    let lastError: unknown;
    for (let attempt = 1; attempt <= retries; attempt++) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), ENV.HTTP_TIMEOUT_MS);
      try {
        this.breaker.beforeRequest();
        await this.bucket.take();
        const response = await fetch(url, {
          ...options,
          signal: controller.signal,
          headers: {
            Authorization: `Bearer ${ENV.BRIGHTDATA_TOKEN}`,
            "Content-Type": "application/json",
            Accept: "application/json",
            ...(options.headers || {}),
          },
        });
        const text = await response.text();
        if (!response.ok) {
          const retryable = [408, 409, 425, 429].includes(response.status) || response.status >= 500;
          if (!retryable) {
            this.breaker.failure();
            throw new Error(`Bright Data HTTP ${response.status}: ${text}`);
          }
          throw new Error(`RETRYABLE_HTTP_${response.status}: ${text}`);
        }
        this.breaker.success();
        return JSON.parse(text) as T;
      } catch (error) {
        lastError = error;
        this.breaker.failure();
        const retryable =
          normalizeError(error).includes("RETRYABLE_HTTP") ||
          normalizeError(error).includes("aborted") ||
          normalizeError(error).includes("fetch failed");
        if (!retryable || attempt >= retries) break;
        metrics.retries++;
        const delay = Math.min(90_000, 1_000 * 2 ** attempt + Math.floor(Math.random() * 1_500));
        log("brightdata_retry", { attempt, delay_ms: delay, error: normalizeError(error) });
        await sleep(delay);
      } finally {
        clearTimeout(timeout);
      }
    }
    throw lastError;
  }
  async fetchWebUnlockerHtml(targetUrl: string, retries = ENV.MAX_RETRIES): Promise<string> {
    let lastError: unknown;
    for (let attempt = 1; attempt <= retries; attempt++) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), ENV.HTTP_TIMEOUT_MS);
      try {
        this.breaker.beforeRequest();
        await this.bucket.take();
        const response = await fetch(`${ENV.BASE_URL}/request`, {
          method: "POST",
          signal: controller.signal,
          headers: {
            Authorization: `Bearer ${ENV.BRIGHTDATA_TOKEN}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            zone: ENV.BRIGHTDATA_WEB_UNLOCKER_ZONE,
            url: targetUrl,
            format: "raw",
          }),
        });
        const text = await response.text();
        if (!response.ok) {
          const retryable = [408, 409, 425, 429].includes(response.status) || response.status >= 500;
          if (!retryable) {
            this.breaker.failure();
            throw new Error(`Bright Data Web Unlocker HTTP ${response.status}: ${text}`);
          }
          throw new Error(`RETRYABLE_HTTP_${response.status}: ${text}`);
        }
        this.breaker.success();
        return text;
      } catch (error) {
        lastError = error;
        this.breaker.failure();
        const retryable =
          normalizeError(error).includes("RETRYABLE_HTTP") ||
          normalizeError(error).includes("aborted") ||
          normalizeError(error).includes("fetch failed");
        if (!retryable || attempt >= retries) break;
        metrics.retries++;
        const delay = Math.min(90_000, 1_000 * 2 ** attempt + Math.floor(Math.random() * 1_500));
        log("brightdata_web_unlocker_retry", { attempt, delay_ms: delay, error: normalizeError(error) });
        await sleep(delay);
      } finally {
        clearTimeout(timeout);
      }
    }
    throw lastError;
  }
  async trigger(datasetInput: Array<{ url: string }>): Promise<string> {
    const url = `${ENV.BASE_URL}/datasets/v3/trigger?dataset_id=${ENV.DATASET_ID}&notify=false&include_errors=true`;
    const result = await this.fetchJson<BrightDataTriggerResponse>(url, {
      method: "POST",
      body: JSON.stringify({
        input: datasetInput,
      }),
    });
    if (!result.snapshot_id) {
      throw new Error(`Bright Data did not return snapshot_id: ${JSON.stringify(result)}`);
    }
    return result.snapshot_id;
  }
  async waitForSnapshot(snapshotId: string): Promise<void> {
    const started = Date.now();
    for (let attempt = 1; attempt <= ENV.MAX_POLLS; attempt++) {
      if (shutdownRequested) throw new Error("Shutdown requested while polling snapshot");
      const result = await this.fetchJson<BrightDataProgressResponse>(
        `${ENV.BASE_URL}/datasets/v3/progress/${snapshotId}`,
        { method: "GET" },
        3
      );
      const status = String(result.status || "").toLowerCase();
      log("snapshot_poll", {
        status,
        attempt,
        elapsed_ms: Date.now() - started,
        records: result.records ?? null,
        errors: result.errors ?? null,
      });
      if (["ready", "done", "completed"].includes(status)) return;
      if (["failed", "error", "cancelled"].includes(status)) {
        throw new Error(`Bright Data snapshot failed: ${JSON.stringify(result)}`);
      }
      await sleep(ENV.POLL_INTERVAL_MS);
    }
    throw new Error(`Timed out waiting for snapshot ${snapshotId}`);
  }
  async downloadSnapshot(snapshotId: string, applyLimit = true): Promise<BestBuyRow[]> {
    const rows = await this.fetchJson<BestBuyRow[]>(
      `${ENV.BASE_URL}/datasets/v3/snapshot/${snapshotId}?format=json`,
      { method: "GET" },
      8
    );
    if (!Array.isArray(rows)) throw new Error("Bright Data snapshot response was not a JSON array");
    return applyLimit && ENV.MAX_ROWS > 0 ? rows.slice(0, ENV.MAX_ROWS) : rows;
  }
}
class SnapshotValidator {
  validateRow(row: BestBuyRow): { productKey: string; sourceUrl: string; title: string | null; rowHash: string } {
    const productKey = this.extractProductKey(row);
    if (!productKey) throw new Error("VALIDATION: Missing Best Buy product key");
    const sourceUrl = this.extractUrl(row, productKey);
    if (!sourceUrl || !sourceUrl.includes("bestbuy.com")) {
      throw new Error("VALIDATION: Invalid Best Buy source URL");
    }
    if (!this.extractTitle(row)) {
      throw new Error("VALIDATION: Missing product title");
    }
    if (row.images !== undefined && !isArrayLike(row.images)) throw new Error("VALIDATION: images must be array");
    if (row.breadcrumbs !== undefined && !isArrayLike(row.breadcrumbs)) throw new Error("VALIDATION: breadcrumbs must be array");
    if (row.product_specifications !== undefined && !isArrayLike(row.product_specifications)) {
      throw new Error("VALIDATION: product_specifications must be array");
    }
    const currency = row.currency ? String(row.currency) : "USD";
    if (currency.length !== 3) throw new Error("VALIDATION: invalid currency");
    for (const price of [row.final_price, row.sale_price, row.offer_price, row.initial_price]) {
      const parsed = parseMoney(price);
      if (price !== undefined && price !== null && parsed === null) {
        throw new Error("VALIDATION: invalid price field");
      }
    }
    return {
      productKey,
      sourceUrl,
      title: this.extractTitle(row),
      rowHash: stableHash(row),
    };
  }
  private extractProductKey(row: BestBuyRow): string {
    const url = String(row.url || row.product_url || "");
    const skuFromUrl = url.match(/skuId=(\d+)/)?.[1];
    return String(row.product_id || row.sku || row.skuId || row.sku_id || row.id || skuFromUrl || "").trim();
  }
  private extractUrl(row: BestBuyRow, productKey: string): string {
    return String(row.url || row.product_url || `https://www.bestbuy.com/site/.p?skuId=${productKey}`).trim();
  }
  private extractTitle(row: BestBuyRow): string | null {
    const title = row.title || row.product_name || row.name || row.short_description || null;
    return title ? String(title).trim() : null;
  }
}
class CollectionRunManager {
  async start(client: PoolClient): Promise<string> {
    const result = await client.query(
      `
      select retail.start_collection_run(
        'best_buy',
        null,
        'brightdata_bestbuy_search_worker',
        'typescript_green_tier1_v2_worker',
        $1::jsonb
      ) as run_id
      `,
      [JSON.stringify({
        source: "brightdata",
        retailer: "best_buy",
        dataset_id: ENV.DATASET_ID,
        mode: "search_url_trigger",
        limit_per_input: payload.limit_per_input,
        input_count: getConfiguredInputUrls().length,
        payload_hash: stableHash({ ...payload, input: getConfiguredInputUrls() }),
      })]
    );
    return result.rows[0].run_id;
  }
  async saveSnapshot(client: PoolClient, runId: string, snapshotId: string): Promise<void> {
    await client.query(
      `
      update retail.collection_runs
      set run_metadata = coalesce(run_metadata, '{}'::jsonb) || $2::jsonb
      where id = $1::uuid
      `,
      [runId, JSON.stringify({ snapshot_id: snapshotId, snapshot_saved_at: new Date().toISOString() })]
    );
  }
  async saveCheckpoint(client: PoolClient, runId: string, checkpoint: Record<string, unknown>): Promise<void> {
    await client.query(
      `
      update retail.collection_runs
      set run_metadata = coalesce(run_metadata, '{}'::jsonb) || jsonb_build_object('checkpoint', $2::jsonb)
      where id = $1::uuid
      `,
      [runId, JSON.stringify(checkpoint)]
    );
  }
  async complete(client: PoolClient, args: {
    runId: string;
    status: RunStatus;
    failureReason?: string;
  }): Promise<void> {
    await client.query(
      `
      call retail.complete_collection_run(
        $1::uuid,
        $2::retail.collection_status,
        $3::int,
        $4::int,
        $5::int,
        $6::int,
        $7::text,
        $8::jsonb
      )
      `,
      [
        args.runId,
        args.status,
        metrics.totalRows,
        metrics.collected,
        metrics.failed,
        metrics.skipped,
        args.failureReason ?? null,
        JSON.stringify(metrics),
      ]
    );
  }
}
class DeadLetterService {
  async write(client: PoolClient, args: {
    row?: BestBuyRow;
    error: unknown;
    classification?: DeadLetterClass;
    rowHash?: string;
  }): Promise<void> {
    const classification = args.classification ?? classifyError(args.error);
    await client.query(
      `
      insert into retail.data_quality_events (
        event_code,
        severity,
        event_message,
        event_json,
        resolved
      )
      values ($1, 'critical', $2, $3::jsonb, false)
      `,
      [
        `BESTBUY_${classification}`,
        normalizeError(args.error),
        JSON.stringify({
          retailer: "best_buy",
          dataset_id: ENV.DATASET_ID,
          snapshot_id: metrics.snapshotId ?? null,
          run_id: metrics.runId ?? null,
          classification,
          row_hash: args.rowHash ?? null,
          row: args.row ?? null,
        }),
      ]
    );
    metrics.deadLetters++;
  }
}
class RawCaptureWriter {
  async write(client: PoolClient, runId: string, row: BestBuyRow, validated: ReturnType<SnapshotValidator["validateRow"]>): Promise<string> {
    const result = await client.query(
      `
      select retail.ingest_raw_product_capture(
        'best_buy',
        $1::uuid,
        $2::text,
        $3::text,
        $4::text,
        $5::text,
        $6::text,
        $7::jsonb,
        'brightdata_bestbuy_v1',
        $8::jsonb
      ) as raw_capture_id
      `,
      [
        runId,
        validated.productKey,
        validated.sourceUrl,
        validated.title,
        row.brand ?? null,
        row.product_category ?? row.root_category ?? row.category_path ?? row.breadcrumb_text ?? null,
        JSON.stringify(row),
        JSON.stringify({
          source: "brightdata",
          retailer: "best_buy",
          dataset_id: ENV.DATASET_ID,
          mode: "search_url_trigger",
          snapshot_id: metrics.snapshotId,
          row_hash: validated.rowHash,
        }),
      ]
    );
    return result.rows[0].raw_capture_id;
  }
}
class BestBuyParser {
  async parse(client: PoolClient, rawCaptureId: string, row: BestBuyRow): Promise<string> {
    const result = await client.query(
      `
      select retail.ingest_brightdata_bestbuy_product(
        $1::uuid,
        $2::jsonb
      ) as bestbuy_parsed_id
      `,
      [rawCaptureId, JSON.stringify(row)]
    );
    return result.rows[0].bestbuy_parsed_id;
  }
}
class PromotionWorker {
  async promote(client: PoolClient, parsedId: string): Promise<void> {
    if (!ENV.PROMOTE_SYNC) return;
    await client.query(`select retail.promote_bestbuy_parsed_product($1::uuid)`, [parsedId]);
  }
}
class BestBuyWorkerHost {
  private readonly db = new DatabaseExecutor(pool);
  private readonly brightData = new BrightDataClient();
  private readonly validator = new SnapshotValidator();
  private readonly runManager = new CollectionRunManager();
  private readonly deadLetter = new DeadLetterService();
  private readonly rawWriter = new RawCaptureWriter();
  private readonly parser = new BestBuyParser();
  private readonly promoter = new PromotionWorker();
  async run(): Promise<void> {
    const lockClient = await pool.connect();
    let lockAcquired = false;
    try {
      lockAcquired = await this.acquireLock(lockClient);
      if (!lockAcquired) {
        log("job_lock_denied");
        process.exitCode = 2;
        return;
      }
      // 1. Classification
      const inputUrls = getConfiguredInputUrls();
      const searchUrls: string[] = [];
      const directProductUrls: string[] = [];
      for (const url of inputUrls) {
        if (isSearchOrCategoryUrl(url)) {
          searchUrls.push(url);
        } else {
          directProductUrls.push(url);
        }
      }
      const hasSearchUrls = searchUrls.length > 0;
      assertEnv(hasSearchUrls);
      // 2. Product Discovery (if search/category URLs are present)
      let discoveredProductUrls: string[] = [];
      if (hasSearchUrls) {
        metrics.stage = "discovery";
        log("discovery_started", { search_urls_count: searchUrls.length });
        discoveredProductUrls = await this.discoverProductUrls(searchUrls, payload.limit_per_input);
        log("discovery_finished", { discovered_urls_count: discoveredProductUrls.length });
      }
      // Merge & deduplicate product URLs
      const combinedProductUrlsSet = new Set([...directProductUrls, ...discoveredProductUrls]);
      const combinedProductUrls = Array.from(combinedProductUrlsSet);
      log("deduplicated_product_urls", { count: combinedProductUrls.length });
      if (combinedProductUrls.length === 0) {
        throw new Error("No product URLs were discovered or provided to scrape.");
      }
      const datasetInput = combinedProductUrls.map((url) => ({ url }));
      metrics.stage = "trigger";
      let t = Date.now();
      metrics.snapshotId = await this.brightData.trigger(datasetInput);
      metrics.triggerMs = Date.now() - t;
      metrics.stage = "collection_run";
      metrics.runId = await this.runManager.start(lockClient);
      await this.runManager.saveSnapshot(lockClient, metrics.runId, metrics.snapshotId);
      metrics.stage = "poll";
      t = Date.now();
      await this.brightData.waitForSnapshot(metrics.snapshotId);
      metrics.pollMs = Date.now() - t;
      metrics.stage = "download";
      t = Date.now();
      let rows = await this.brightData.downloadSnapshot(metrics.snapshotId, false);
      metrics.downloadMs = Date.now() - t;

      if (ENV.RETRY_TIMEOUT_ROWS) {
        rows = await this.retryTimeoutRows(rows);
      }
      rows = orderRowsForProcessing(rows);
      rows = ENV.MAX_ROWS > 0 ? rows.slice(0, ENV.MAX_ROWS) : rows;

      metrics.totalRows = rows.length;
      metrics.stage = "ingest";
      t = Date.now();
      await this.processRows(rows);
      metrics.ingestMs = Date.now() - t;
      const status: RunStatus = metrics.failed === 0 ? "completed" : metrics.collected > 0 ? "partial" : "failed";
      await this.runManager.complete(lockClient, { runId: metrics.runId, status });
      this.logComplete(status);
    } catch (error) {
      log("worker_failed", { classification: classifyError(error), error: normalizeError(error) });
      if (metrics.runId) {
        await this.deadLetter.write(lockClient, { error });
        await this.runManager.complete(lockClient, {
          runId: metrics.runId,
          status: "failed",
          failureReason: normalizeError(error),
        });
      }
      process.exitCode = 1;
    } finally {
      if (lockAcquired) await this.releaseLock(lockClient);
      lockClient.release();
    }
  }
  private async discoverProductUrls(searchUrls: string[], limitPerInput: number): Promise<string[]> {
    const allProductUrls = new Set<string>();
    for (const searchUrl of searchUrls) {
      log("discovery_query_started", { query_url: searchUrl });
      let page = 1;
      let totalFoundForQuery = 0;
      let consecutiveEmptyPages = 0;
      while (totalFoundForQuery < limitPerInput && consecutiveEmptyPages < 2) {
        if (shutdownRequested) throw new Error("Shutdown requested during discovery");
        const pageUrl = getPaginatedUrl(searchUrl, page);
        log("discovery_page_fetching", { page, page_url: pageUrl });
        try {
          const html = await this.brightData.fetchWebUnlockerHtml(pageUrl);
          const productUrls = extractProductUrlsFromHtml(html);
          log("discovery_page_fetched", { page, urls_found: productUrls.length });
          if (productUrls.length === 0) {
            consecutiveEmptyPages++;
            page++;
            continue;
          }
          consecutiveEmptyPages = 0;
          let newUrlsAdded = 0;
          for (const productUrl of productUrls) {
            if (!allProductUrls.has(productUrl)) {
              allProductUrls.add(productUrl);
              newUrlsAdded++;
              totalFoundForQuery++;
            }
            if (totalFoundForQuery >= limitPerInput) break;
          }
          log("discovery_page_summary", { page, new_urls_added: newUrlsAdded, total_query_found: totalFoundForQuery });
          if (newUrlsAdded === 0) {
            log("discovery_no_new_urls_stop", { page });
            break;
          }
          page++;
          await sleep(1000);
        } catch (error) {
          log("discovery_page_failed", { page_url: pageUrl, error: normalizeError(error) });
          break;
        }
      }
    }
    return Array.from(allProductUrls);
  }

  private async retryTimeoutRows(rows: BestBuyRow[]): Promise<BestBuyRow[]> {
    const retryableRows = rows.filter(isRetryableBrightDataErrorRow);
    if (retryableRows.length === 0) return rows;

    const retryUrls = Array.from(new Set(
      retryableRows
        .map(getBrightDataInputUrl)
        .filter((url): url is string => Boolean(url))
    ));

    if (retryUrls.length === 0) return rows;

    log("timeout_retry_started", { retry_url_count: retryUrls.length });

    try {
      const retrySnapshotId = await this.brightData.trigger(retryUrls.map((url) => ({ url })));
      log("timeout_retry_snapshot_triggered", { retry_snapshot_id: retrySnapshotId });

      await this.brightData.waitForSnapshot(retrySnapshotId);
      const retryRows = await this.brightData.downloadSnapshot(retrySnapshotId, false);

      const nonRetryRows = rows.filter((row) => !isRetryableBrightDataErrorRow(row));

      log("timeout_retry_complete", {
        retry_snapshot_id: retrySnapshotId,
        retry_rows: retryRows.length,
        original_retryable_rows: retryableRows.length,
      });

      return [...nonRetryRows, ...retryRows];
    } catch (error) {
      log("timeout_retry_failed", {
        retry_url_count: retryUrls.length,
        error: normalizeError(error),
      });

      return rows;
    }
  }

  private async processRows(rows: BestBuyRow[]): Promise<void> {
    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (cursor < rows.length && !shutdownRequested) {
        const index = cursor++;
        const row = rows[index];
        if (row?.error || row?.error_code) {
          metrics.skipped++;
          metrics.processed++;
          await this.db.tx(async (client) => {
            await this.deadLetter.write(client, {
              row,
              error: new Error(`Bright Data row error: ${row.error_code || "unknown"} ${row.error || ""}`.trim()),
              classification: "API_FAILURE"
            });
          });
          log("skipped_error_row", {
            row_index: index,
            error_code: row.error_code,
            error: row.error,
          });
          continue;
        }
        await this.db.tx(async (client) => {
          let validated;
          try {
            validated = this.validator.validateRow(row);
          } catch (valError) {
            metrics.failed++;
            metrics.processed++;
            await this.deadLetter.write(client, {
              row,
              error: valError,
              classification: "VALIDATION_FAILURE",
            });
            log("row_validation_failed", {
              row_index: index,
              error: normalizeError(valError),
            });
            return;
          }
          try {
            const rawCaptureId = await this.rawWriter.write(client, metrics.runId!, row, validated);
            const parsedId = await this.parser.parse(client, rawCaptureId, row);
            await this.promoter.promote(client, parsedId);
            metrics.collected++;
            metrics.processed++;
            if (metrics.processed % 100 === 0) {
              await this.runManager.saveCheckpoint(client, metrics.runId!, {
                processed: metrics.processed,
                collected: metrics.collected,
                failed: metrics.failed,
                last_index: index,
                last_row_hash: validated.rowHash,
              });
              log("ingest_progress", { processed: metrics.processed, collected: metrics.collected, failed: metrics.failed });
            }
          } catch (error) {
            metrics.failed++;
            metrics.processed++;
            await this.deadLetter.write(client, {
              row,
              error,
              rowHash: validated.rowHash,
              classification: classifyError(error),
            });
            log("row_ingestion_failed", {
              row_index: index,
              row_hash: validated.rowHash,
              classification: classifyError(error),
              error: normalizeError(error),
            });
          }
        });
      }
    };
    await Promise.all(Array.from({ length: ENV.CONCURRENCY }, () => worker()));
  }
  private async acquireLock(client: PoolClient): Promise<boolean> {
    const result = await client.query(`select pg_try_advisory_lock($1) as locked`, [LOCK_KEY]);
    return result.rows[0]?.locked === true;
  }
  private async releaseLock(client: PoolClient): Promise<void> {
    await client.query(`select pg_advisory_unlock($1)`, [LOCK_KEY]);
  }
  private logComplete(status: RunStatus): void {
    const elapsed = (Date.now() - metrics.startedAt) / 1000;
    const rowsPerSecond = metrics.totalRows > 0 ? metrics.totalRows / elapsed : 0;
    const failureRate = metrics.totalRows > 0 ? metrics.failed / metrics.totalRows : 0;
    log("worker_complete", {
      ok: status !== "failed",
      status,
      total_rows: metrics.totalRows,
      processed: metrics.processed,
      collected: metrics.collected,
      failed: metrics.failed,
      dead_letters: metrics.deadLetters,
      rows_per_second: Number(rowsPerSecond.toFixed(4)),
      failure_rate: Number(failureRate.toFixed(4)),
      elapsed_seconds: Number(elapsed.toFixed(2)),
      retries: metrics.retries,
      circuit_open_count: metrics.circuitOpenCount,
    });
  }
}
function startHealthServer(): http.Server {
  const server = http.createServer((req: http.IncomingMessage, res: http.ServerResponse) => {
    if (req.url === "/health") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        ok: true,
        service: "brightdata_bestbuy_search_ingest",
        stage: metrics.stage,
        run_id: metrics.runId ?? null,
        snapshot_id: metrics.snapshotId ?? null,
        uptime_seconds: Number(((Date.now() - metrics.startedAt) / 1000).toFixed(2)),
      }));
      return;
    }
    if (req.url === "/metrics") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(metrics));
      return;
    }
    res.writeHead(404);
    res.end();
  });
  server.listen(ENV.HEALTH_PORT, () => {
    log("health_server_started", { port: ENV.HEALTH_PORT });
  });
  return server;
}
async function main(): Promise<void> {
  assertEnv(false); // check standard variables first, we'll verify unlocker dynamically
  process.on("SIGINT", () => {
    shutdownRequested = true;
    log("shutdown_requested", { signal: "SIGINT" });
  });
  process.on("SIGTERM", () => {
    shutdownRequested = true;
    log("shutdown_requested", { signal: "SIGTERM" });
  });
  const healthServer = startHealthServer();
  try {
    await new BestBuyWorkerHost().run();
  } finally {
    healthServer.close();
    await pool.end();
  }
}
main();
