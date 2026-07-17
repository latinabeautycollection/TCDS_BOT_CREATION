# TCDS Costco Bright Data Enterprise Ingest

Production TypeScript ingestion worker for Bright Data Costco dataset `gd_mkcbmac44j178pook`, with category discovery through the standard `tcds_web_unlocker` zone.

## Architecture

1. Validates that every seed is HTTPS and belongs to Costco.
2. Creates a governed `retail.collection_runs` record with a unique run key.
3. Uses the standard Web Unlocker zone to discover canonical Costco PDP URLs from category seeds.
4. Triggers Bright Data's asynchronous detail dataset with PDP URLs and `limit_per_input=1`.
5. Polls snapshot progress with bounded retries, timeout, jitter, `Retry-After`, and delayed 404 tolerance.
6. Downloads JSON or JSONL snapshot data and separates provider errors from product rows.
7. Validates every Costco record with Zod.
8. Writes each product atomically into raw capture, Costco parsed, canonical product, price history, inventory history, offer snapshot, current offer, image, and category tables.
9. Dead-letters provider errors as abandoned and ingestion failures as retryable.
10. Replays retryable DLQ records through a separate atomically claimed command.

## Critical behavior

- `404` from Bright Data progress during the first minute is treated as eventual snapshot visibility and retried.
- A Costco HTML response containing common page-not-found markers is classified as a logical 404 even when the upstream HTTP status is 200.
- HTTP 408, 425, 429, 500, 502, 503, and 504 are retried with exponential backoff and full jitter.
- Authentication, invalid dataset, validation, and permanent 4xx failures are not endlessly retried.
- Secrets and authorization values are redacted from structured logs.
- Every product transaction rolls back completely when any required shared-schema write fails.
- Discovery is capped at 50 unique products by default.
- Premium Unlocker fallback is disabled by default; detail collection never invokes Unlocker.
- Empty snapshots fail the run instead of reporting a false completion.

## Install

```bash
cp .env.example .env
npm ci
npm run migrate
npm run typecheck
npm run build
npm start
```

## DLQ replay

```bash
npm run dlq:replay
```

Run replay from one scheduled worker only. PostgreSQL row locking and status transitions prevent uncontrolled duplicate processing.

## Seed management

The supplied seeds are broad category pages:

- `https://www.costco.com/laptops.html`
- `https://www.costco.com/tablet-computers-accessories.html`
- `https://www.costco.com/aerial-cameras.html`

They are not automatically classified as clearance or discount feeds. Records are stored truthfully with regular and sale prices for downstream discount intelligence and Prong 2 matching.

## Deployment requirements

- Node.js 20.11+
- PostgreSQL with the existing TCDS `retail` schema
- Bright Data API token in a secret manager
- Exactly one scheduler leader, or a distributed scheduler lock
- Outbound HTTPS access to `api.brightdata.com`
- Monitoring on run failure rate, empty snapshots, DLQ growth, unlocker escalation, collection duration, and record acceptance ratio
