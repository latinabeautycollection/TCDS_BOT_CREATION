import { z } from "zod";
import type { AppConfig } from "./config.js";
import type { Logger } from "./logger.js";
import { sleep } from "./util.js";

const TriggerResponse = z.object({ snapshot_id: z.string().min(1) }).passthrough();
const ProgressResponse = z.object({ status: z.string().min(1) }).passthrough();

export class BrightDataClient {
  constructor(private readonly cfg: AppConfig, private readonly log: Logger) {}

  private async request(url: string, init: RequestInit, ok = [200]): Promise<Response> {
    let last: unknown;
    for (let attempt = 0; attempt <= this.cfg.BRIGHT_DATA_MAX_HTTP_RETRIES; attempt++) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), this.cfg.BRIGHT_DATA_HTTP_TIMEOUT_MS);
      try {
        const response = await fetch(url, {
          ...init,
          signal: controller.signal,
          headers: {
            Authorization: `Bearer ${this.cfg.BRIGHT_DATA_API_TOKEN}`,
            Accept: "application/json",
            "Content-Type": "application/json",
            ...(init.headers ?? {})
          }
        });
        if (ok.includes(response.status)) return response;
        const body = await response.text();
        const retryable = response.status === 408 || response.status === 409 ||
          response.status === 425 || response.status === 429 || response.status >= 500;
        if (!retryable || attempt === this.cfg.BRIGHT_DATA_MAX_HTTP_RETRIES) {
          throw new Error(`Bright Data HTTP ${response.status}: ${body.slice(0, 1500)}`);
        }
        this.log.warn({ attempt, status: response.status }, "brightdata_retryable_response");
      } catch (error) {
        last = error;
        if (attempt === this.cfg.BRIGHT_DATA_MAX_HTTP_RETRIES) throw error;
        this.log.warn({ attempt, error: error instanceof Error ? error.message : String(error) }, "brightdata_request_retry");
      } finally {
        clearTimeout(timer);
      }
      await sleep(Math.min(30000, 1000 * 2 ** attempt) + Math.floor(Math.random() * 500));
    }
    throw last instanceof Error ? last : new Error("Bright Data request failed");
  }

  async fetchWebUnlockerHtml(url: string): Promise<string> {
    const response = await this.request(
      `${this.cfg.BRIGHT_DATA_BASE_URL}/request`,
      { method: "POST", body: JSON.stringify({ zone: this.cfg.BRIGHT_DATA_WEB_UNLOCKER_ZONE, url, format: "raw" }) }
    );
    return await response.text();
  }

  async trigger(input: Array<{url: string}>, limitPerInput = 1): Promise<{snapshotId: string; providerResponse: unknown}> {
    const q = new URLSearchParams({
      dataset_id: this.cfg.BRIGHT_DATA_DATASET_ID,
      notify: String(this.cfg.BRIGHT_DATA_NOTIFY),
      include_errors: String(this.cfg.BRIGHT_DATA_INCLUDE_ERRORS)
    });
    const response = await this.request(
      `${this.cfg.BRIGHT_DATA_BASE_URL}/datasets/v3/trigger?${q}`,
      { method: "POST", body: JSON.stringify({ input, limit_per_input: limitPerInput }) },
      [200, 201, 202]
    );
    const raw: unknown = await response.json();
    const parsed = TriggerResponse.safeParse(raw);
    if (!parsed.success) throw new Error(`Trigger response did not contain snapshot_id: ${JSON.stringify(raw)}`);
    return { snapshotId: parsed.data.snapshot_id, providerResponse: raw };
  }

  async wait(snapshotId: string): Promise<Record<string, unknown>> {
    const deadline = Date.now() + this.cfg.BRIGHT_DATA_MAX_WAIT_MS;
    while (Date.now() < deadline) {
      const response = await this.request(
        `${this.cfg.BRIGHT_DATA_BASE_URL}/datasets/v3/progress/${encodeURIComponent(snapshotId)}`,
        { method: "GET" }
      );
      const raw: unknown = await response.json();
      const parsed = ProgressResponse.safeParse(raw);
      if (!parsed.success) throw new Error(`Invalid progress response: ${JSON.stringify(raw)}`);
      const status = parsed.data.status.toLowerCase();
      this.log.info({ snapshot_id: snapshotId, status }, "brightdata_progress");
      if (["ready", "done", "completed", "success"].includes(status)) return parsed.data;
      if (["failed", "error", "cancelled", "canceled"].includes(status)) {
        throw new Error(`Snapshot ${snapshotId} failed with status ${status}`);
      }
      await sleep(this.cfg.BRIGHT_DATA_POLL_INTERVAL_MS);
    }
    throw new Error(`Timed out waiting for snapshot ${snapshotId}`);
  }

  async download(snapshotId: string): Promise<unknown[]> {
    const response = await this.request(
      `${this.cfg.BRIGHT_DATA_BASE_URL}/datasets/v3/snapshot/${encodeURIComponent(snapshotId)}?format=json`,
      { method: "GET" }
    );
    const body = await response.text();
    if (!body.trim()) return [];
    const contentType = response.headers.get("content-type") ?? "";
    if (contentType.includes("ndjson") || body.trimStart().startsWith("{") && body.includes("\n{")) {
      return body.split(/\r?\n/).filter(Boolean).map((line, i) => {
        try { return JSON.parse(line); }
        catch { throw new Error(`Invalid NDJSON at line ${i + 1}`); }
      });
    }
    const parsed: unknown = JSON.parse(body);
    if (Array.isArray(parsed)) return parsed;
    if (parsed && typeof parsed === "object") {
      const o = parsed as Record<string, unknown>;
      if (Array.isArray(o.data)) return o.data;
      if (Array.isArray(o.results)) return o.results;
    }
    return [parsed];
  }
}
