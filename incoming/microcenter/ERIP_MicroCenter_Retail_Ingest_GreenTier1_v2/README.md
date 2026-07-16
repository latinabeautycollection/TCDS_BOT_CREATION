# ERIP Micro Center Retail Ingest — Green Tier 1 v2

This package writes **only to the `retail` schema**. It does not write to `arb`.

## Data flow

Bright Data → `retail.collection_runs` → `retail.raw_product_captures` →
`retail.retail_products` → `retail.retail_offer_snapshots` →
`retail.product_price_history` / `retail.product_inventory_history`

Malformed or low-confidence data goes to `retail.data_quality_events`.

## Bright Data workflow

The runner uses the supported asynchronous sequence:

1. `POST /datasets/v3/trigger`
2. poll `GET /datasets/v3/progress/{snapshot_id}` until ready
3. download `GET /datasets/v3/snapshot/{snapshot_id}?format=json`

The code also supports file/S3 delivery mode through `ingest-file`.

## First installation

```bash
sudo mkdir -p /srv/erip/microcenter-ingest
sudo chown -R erip:erip /srv/erip/microcenter-ingest
cd /srv/erip/microcenter-ingest
cp .env.example .env
npm ci
npm run typecheck
```

Run `sql/001_retail_microcenter_ingest.sql` once in Supabase SQL Editor.

## Commands

```bash
npm run health
npm run run
npm run trigger
npm run resume -- --run-id=<uuid> --snapshot-id=<snapshot_id>
npm run ingest:file -- --file=/srv/erip/inbox/microcenter.ndjson
```

## Required acceptance procedure

The sample provided with the request was the trigger request, not a returned product record. Therefore the normalizer is intentionally defensive and raw-first.

Before enabling the daily timer:

1. Set `BRIGHT_DATA_LIMIT_PER_INPUT=10`.
2. Run one collection.
3. Inspect `retail.raw_product_captures.payload`.
4. Update `src/normalizer.ts` with the exact returned field names.
5. Run a 100-record acceptance test.
6. Require:
   - successful run status;
   - 0 unhandled exceptions;
   - quarantine rate below the configured threshold;
   - duplicate handling proven idempotent;
   - correct price, inventory, title, URL, SKU and identifier mappings.
7. Increase the limit only after validation.

## Enterprise controls included

- `retail` schema ownership
- PostgreSQL transactions
- advisory lock preventing overlapping daily runs
- deterministic run keys
- immutable collection runs
- raw-first evidence landing
- idempotent record and offer hashes
- bounded HTTP retries with exponential backoff and jitter
- request timeouts
- typed environment validation
- structured logs with secret redaction
- quality quarantine and threshold failure
- price and inventory history
- normalized product upsert
- execution resume support
- file/S3 ingestion support
- systemd sandboxing
- no API tokens in source code
- nonzero process exit on failure

## Important integration note

If your existing `retail.*` tables already exist with different columns, do not run the migration blindly. Diff `sql/001_retail_microcenter_ingest.sql` against the current Supabase schema and adapt the repository column mapping while preserving the same ownership and transaction model.
