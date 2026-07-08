import { Pool, PoolClient } from "pg";

const BRIGHTDATA_TOKEN = process.env.BRIGHTDATA_TOKEN!;
const DATABASE_URL = process.env.DATABASE_URL!;

const DATASET_ID = "gd_l95fol7l1ru6rlo116";
const BASE_URL = "https://api.brightdata.com";

const pool = new Pool({ connectionString: DATABASE_URL });

const input = [
  {
    url: "https://www.walmart.com/ip/Marketside-Fresh-Organic-Bananas-Bunch/51259338",
  },
];

function assertEnv() {
  if (!BRIGHTDATA_TOKEN) throw new Error("Missing BRIGHTDATA_TOKEN");
  if (!DATABASE_URL) throw new Error("Missing DATABASE_URL");
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function brightDataFetch<T>(
  url: string,
  options: RequestInit = {},
  retries = 5
): Promise<T> {
  let lastError: unknown;

  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const response = await fetch(url, {
        ...options,
        headers: {
          Authorization: `Bearer ${BRIGHTDATA_TOKEN}`,
          "Content-Type": "application/json",
          Accept: "application/json",
          ...(options.headers || {}),
        },
      });

      const text = await response.text();

      if (!response.ok) {
        const retryable =
          response.status === 408 ||
          response.status === 429 ||
          response.status >= 500;

        if (retryable && attempt < retries) {
          await sleep(3000 * attempt);
          continue;
        }

        throw new Error(`Bright Data HTTP ${response.status}: ${text}`);
      }

      return JSON.parse(text) as T;
    } catch (error) {
      lastError = error;

      if (attempt < retries) {
        await sleep(3000 * attempt);
        continue;
      }
    }
  }

  throw lastError;
}

async function triggerBrightData(): Promise<string> {
  const url =
    `${BASE_URL}/datasets/v3/trigger` +
    `?dataset_id=${DATASET_ID}` +
    `&notify=false` +
    `&include_errors=true`;

  const result = await brightDataFetch<{ snapshot_id: string }>(url, {
    method: "POST",
    body: JSON.stringify(input),
  });

  if (!result.snapshot_id) {
    throw new Error(`No snapshot_id returned: ${JSON.stringify(result)}`);
  }

  return result.snapshot_id;
}

async function waitForSnapshot(snapshotId: string): Promise<void> {
  for (let i = 1; i <= 120; i++) {
    const result = await brightDataFetch<any>(
      `${BASE_URL}/datasets/v3/progress/${snapshotId}`,
      { method: "GET" },
      3
    );

    const status = String(result.status || "").toLowerCase();

    console.log(`Snapshot ${snapshotId} status: ${status}`);

    if (["ready", "done", "completed"].includes(status)) return;

    if (["failed", "error", "cancelled"].includes(status)) {
      throw new Error(`Snapshot failed: ${JSON.stringify(result)}`);
    }

    await sleep(15000);
  }

  throw new Error(`Timed out waiting for snapshot ${snapshotId}`);
}

async function downloadSnapshot(snapshotId: string): Promise<any[]> {
  const rows = await brightDataFetch<any[]>(
    `${BASE_URL}/datasets/v3/snapshot/${snapshotId}?format=json`,
    { method: "GET" },
    8
  );

  if (!Array.isArray(rows)) {
    throw new Error("Snapshot response was not a JSON array.");
  }

  return rows;
}

async function createCollectionRun(client: PoolClient): Promise<string> {
  const result = await client.query(
    `
    select retail.start_collection_run(
      'walmart',
      null,
      'brightdata_test_worker',
      'typescript_fetch_test',
      '{"source":"brightdata","mode":"end_to_end_test"}'::jsonb
    ) as run_id
    `
  );

  return result.rows[0].run_id;
}

async function completeCollectionRun(
  client: PoolClient,
  runId: string,
  status: "completed" | "partial" | "failed",
  totalRequested: number,
  totalCollected: number,
  totalFailed: number,
  snapshotId: string,
  failureReason?: string
) {
  await client.query(
    `
    call retail.complete_collection_run(
      $1::uuid,
      $2::retail.collection_status,
      $3::int,
      $4::int,
      $5::int,
      0::int,
      $6::text,
      $7::jsonb
    )
    `,
    [
      runId,
      status,
      totalRequested,
      totalCollected,
      totalFailed,
      failureReason || null,
      JSON.stringify({ snapshot_id: snapshotId }),
    ]
  );
}

async function deadLetter(
  client: PoolClient,
  row: any,
  snapshotId: string,
  error: unknown
) {
  await client.query(
    `
    insert into retail.data_quality_events (
      event_code,
      severity,
      event_message,
      event_json,
      resolved
    )
    values (
      'WALMART_BRIGHTDATA_ROW_FAILED',
      'critical',
      $1,
      $2::jsonb,
      false
    )
    `,
    [
      error instanceof Error ? error.message : String(error),
      JSON.stringify({
        source: "brightdata_walmart",
        snapshot_id: snapshotId,
        row,
      }),
    ]
  );
}

async function ingestOneRow(
  client: PoolClient,
  row: any,
  runId: string
): Promise<void> {
  const productKey = String(row.product_id || row.sku || row.url || "").trim();

  if (!productKey) {
    throw new Error("Missing product_id, sku, and url.");
  }

  const sourceUrl = row.url || `https://www.walmart.com/ip/${productKey}`;

  const rawResult = await client.query(
    `
    select retail.ingest_raw_product_capture(
      'walmart',
      $1::uuid,
      $2::text,
      $3::text,
      $4::text,
      $5::text,
      $6::text,
      $7::jsonb,
      'brightdata_walmart_v1',
      '{"source":"brightdata","retailer":"walmart"}'::jsonb
    ) as raw_capture_id
    `,
    [
      runId,
      productKey,
      sourceUrl,
      row.product_name || row.short_description || null,
      row.brand || null,
      row.product_category || row.category_name || row.breadcrumb_text || null,
      JSON.stringify(row),
    ]
  );

  const rawCaptureId = rawResult.rows[0].raw_capture_id;

  const parsedResult = await client.query(
    `
    select retail.ingest_brightdata_walmart_product(
      $1::uuid,
      $2::jsonb
    ) as walmart_parsed_id
    `,
    [rawCaptureId, JSON.stringify(row)]
  );

  const walmartParsedId = parsedResult.rows[0].walmart_parsed_id;

  await client.query(
    `
    select retail.promote_walmart_parsed_product($1::uuid)
    `,
    [walmartParsedId]
  );
}

async function main() {
  assertEnv();

  const client = await pool.connect();

  let runId: string | null = null;
  let snapshotId: string | null = null;
  let collected = 0;
  let failed = 0;
  let rows: any[] = [];

  try {
    runId = await createCollectionRun(client);

    console.log(`Collection run created: ${runId}`);

    snapshotId = process.env.SNAPSHOT_ID || null;

if (snapshotId) {
  console.log(`Using existing Bright Data snapshot: ${snapshotId}`);
} else {
  snapshotId = await triggerBrightData();

  console.log(`Bright Data snapshot created: ${snapshotId}`);

  await waitForSnapshot(snapshotId);
}

    rows = await downloadSnapshot(snapshotId);

    console.log(`Downloaded ${rows.length} Walmart rows.`);

    for (const row of rows) {
      try {
        await client.query("begin");

        await ingestOneRow(client, row, runId);

        await client.query("commit");

        collected++;
      } catch (error) {
        await client.query("rollback");

        failed++;

        await deadLetter(client, row, snapshotId, error);

        console.error("Row failed:", error);
      }
    }

    await completeCollectionRun(
      client,
      runId,
      failed > 0 ? "partial" : "completed",
      rows.length,
      collected,
      failed,
      snapshotId
    );

    console.log({
      ok: true,
      runId,
      snapshotId,
      totalRows: rows.length,
      collected,
      failed,
    });
  } catch (error) {
    console.error("Worker failed:", error);

    if (runId && snapshotId) {
      await completeCollectionRun(
        client,
        runId,
        "failed",
        rows.length,
        collected,
        failed,
        snapshotId,
        error instanceof Error ? error.message : String(error)
      );
    }

    process.exitCode = 1;
  } finally {
    client.release();
    await pool.end();
  }
}

main();
