# TCDS Harbor Freight Bright Data Enterprise Ingest

Production TypeScript worker for Bright Data dataset `gd_mky1qkjbnsea4buxc`, Harbor Freight category discovery, controlled Web Unlocker evidence capture, PostgreSQL promotion, retry handling, and dead-letter replay.

## Collection inputs

- `https://www.harborfreight.com/power-tools/drills-drivers.html`
- `https://www.harborfreight.com/automotive/diagnostic-testing-scanning.html`
- `https://www.harborfreight.com/automotive/battery-tools-accessories.html`

The trigger uses `type=discover_new` and `discover_by=category_url`.

## Reliability controls

- Bounded retries with exponential backoff, jitter, and `Retry-After`
- HTTP 408, 425, 429, 500, 502, 503, and 504 recovery
- Permanent 4xx classification and bounded snapshot-progress 404 tolerance
- Logical HTTP-200 page-not-found detection
- Standard Web Unlocker fallback
- Provider error rows are counted as skipped and retained in the DLQ
- Completed and partial run statuses reflect row-level outcomes
- PostgreSQL and local forensic dead letters
- Atomic DLQ replay with `FOR UPDATE SKIP LOCKED`
- Idempotent runs, raw captures, products, and offer snapshots
- Per-product PostgreSQL transactions and rollback
- Secret-redacted structured logging

## Harbor Freight-specific controls

- Category discovery does not prove a discount. Records without markdown evidence generate `HARBORFREIGHT_CATEGORY_RESULT_NO_DISCOUNT`.
- Out-of-scope results generate `HARBORFREIGHT_COLLECTION_SCOPE_MISMATCH`.
- Missing prices preserve product and inventory evidence but withhold offer promotion.
- Explicit null arrays are normalized safely.
- Missing product images are accepted.
- Out-of-stock products remain available for price and restock history.

## Database objects

- `retail.harborfreight_product_parsed`
- `retail.harborfreight_product_images`
- `retail.harborfreight_product_categories`
- `retail.harborfreight_product_specifications`
- `retail.harborfreight_unlocker_evidence`

The worker also writes to the shared TCDS retail capture, product, price, inventory, offer, quality-event, and dead-letter tables.

## Deployment

```bash
cp .env.example .env
npm ci
npm run migrate
npm run typecheck
npm run build
npm start
```

Replay eligible dead letters:

```bash
npm run dlq:replay
```

Recommended production setting:

```env
HARBORFREIGHT_UNLOCKER_MODE=fallback
HARBORFREIGHT_UNLOCKER_ZONE_POLICY=standard_only
HARBORFREIGHT_LIMIT_PER_INPUT=50
```
