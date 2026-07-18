# TCDS BJ's Bright Data Enterprise Ingest

Production TypeScript worker for Bright Data BJ's dataset `gd_mm3gd9wmbdp67oxsf`.

## Collection flow

1. Fetch BJ's category pages through the standard Web Unlocker zone.
2. Extract and canonicalize unique product-detail URLs from category cards.
3. Retain only cards that expose a public `data-cnstrc-item-price` value. Cards labelled `Member Only Price` do not expose a price without an authenticated membership and are excluded.
4. Trigger the Bright Data product dataset with the discovered PDP URLs and `limit_per_input: 1`.
5. Validate each dataset row and use its regular/sale price. If the dataset omits both prices, use the public category-card price captured during discovery.
6. Atomically write raw captures, parsed BJ's rows, canonical products, inventory, prices, offers, images, and categories.
7. Dead-letter provider, validation, price, and ingestion failures. Runs finish as `completed`, `partial`, or `failed` based on actual results.

The default run discovers up to 50 products. It uses `tcds_web_unlocker` only; premium-zone escalation is disabled by default.

## Install and run

```bash
cp .env.example .env
npm ci
npm run typecheck
npm test
npm run build
npm run migrate
npm start
```

## DLQ replay

```bash
npm run dlq:replay
```

DLQ claims use a transactional `FOR UPDATE SKIP LOCKED` transition before processing, preventing concurrent workers from claiming the same row.

## Operational notes

- HTTP 408, 425, 429, 500, 502, 503, and 504 are retried with bounded exponential backoff and jitter.
- Empty unlocker bodies and logical 404 pages are rejected.
- Nullable Bright Data array fields normalize to empty arrays.
- Canonical identity uses `variant_id` when present, otherwise `item_id`.
- Missing public prices are rejected rather than promoted as incomplete offers.
- Secrets belong in `.env` or a secret manager; `.env` is ignored by Git.
