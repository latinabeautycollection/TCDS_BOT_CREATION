# TCDS Office Depot Bright Data Enterprise Ingest

Production TypeScript ingestion worker that discovers Office Depot PDP URLs through the standard Web Unlocker and extracts product details with Bright Data dataset `gd_mktjw1cs1bedg8o196`.

## Governed seeds

- `https://www.officedepot.com/l/deal-center/pc-deals`
- `https://www.officedepot.com/b/electronics/Featured_Items--On_Sale/N-9021`
- `https://www.officedepot.com/l/deal-center/printer-deals`

These are discount-oriented collection sources. A source URL does not prove every returned record is relevant or discounted; the worker preserves source truth and emits data-quality evidence for downstream TCDS discount and Prong 2 qualification.

## Processing flow

1. Validate all configured seeds as HTTPS Office Depot URLs.
2. Discover canonical PDP URLs from category pages and pagination through `tcds_web_unlocker`.
3. Create a governed `retail.collection_runs` row for the discovered PDP inputs.
4. Trigger the asynchronous Bright Data dataset with one record per PDP.
5. Poll snapshot progress with bounded timeout and delayed-snapshot 404 tolerance.
6. Download JSON or JSONL data.
7. Validate and normalize each record with Zod, including explicit `null` arrays.
8. Insert each product transactionally into raw capture, Office Depot parsed, canonical product, price, inventory, offer, image, and category tables.
9. Reject missing prices and normalize inverted price fields before canonical promotion.
10. Write failed records to PostgreSQL and local forensic dead letters.
11. Account for provider errors and omitted inputs as skipped records in partial runs.
12. Replay retryable DLQ entries through an atomic claim worker using `FOR UPDATE SKIP LOCKED`.

## Reliability controls

- Retryable statuses: 408, 425, 429, 500, 502, 503, 504.
- Exponential backoff with jitter and `Retry-After` support.
- `AbortController` request timeout.
- Permanent 4xx classification and bounded attempts.
- Bright Data snapshot progress, terminal-state, and maximum-wait enforcement.
- Real HTTP 404 and logical HTTP-200 page-not-found detection.
- Standard Web Unlocker category discovery without premium-zone escalation.
- Empty-snapshot evidence validation.
- Per-product PostgreSQL transactions and rollback.
- Deterministic raw capture, product, offer, run, and DLQ idempotency.
- Structured logging and secret redaction.
- Database and local JSON dead-letter evidence.
- DLQ backoff capped at 24 hours and abandonment after repeated failures.

## Office Depot-specific protections

### Null collections

Office Depot may return `variant_attributes`, `variants`, images, categories, reviews, or target countries as `null`. They are normalized to empty arrays rather than incorrectly dead-lettered.

### Missing price

A product with no usable `price` or `sale_price` is rejected to the dead-letter queue so canonical products and offers remain price-complete.

### Price field inversion

When `sale_price` exceeds `price`, the worker uses the lowest valid observed price and records `OFFICE_DEPOT_PRICE_FIELD_INVERSION` with full evidence.

### Collection-scope mismatch

The supplied example returns a breakroom snack from PC/electronics/printer deal seeds. The worker preserves the record but records `OFFICE_DEPOT_COLLECTION_SCOPE_MISMATCH` and adds `collection_scope_match` to price and offer metadata so ERIP can exclude it.

## Database objects

The migration creates:

- `retail.officedepot_product_parsed`
- `retail.officedepot_product_images`
- `retail.officedepot_product_categories`
- `retail.officedepot_unlocker_evidence`

It integrates with:

- `retail.retail_platforms`
- `retail.platform_collection_configs`
- `retail.collection_runs`
- `retail.raw_product_captures`
- `retail.retail_products`
- `retail.product_price_history`
- `retail.product_inventory_history`
- `retail.retail_offer_snapshots`
- `retail.current_retail_offers`
- `retail.data_quality_events`
- `retail.ingest_dead_letters`

## Deployment

```bash
cp .env.example .env
npm ci
npm run migrate
npm run typecheck
npm run build
npm start
```

Required secrets:

```env
DATABASE_URL=postgresql://...
BRIGHT_DATA_API_TOKEN=...
```

Recommended Unlocker policy:

```env
OFFICE_DEPOT_UNLOCKER_MODE=fallback
OFFICE_DEPOT_UNLOCKER_ZONE_POLICY=standard_only
```

## DLQ replay

```bash
npm run dlq:replay
```

Run one or more replay workers safely; atomic claiming and row locking prevent the same dead letter from being processed concurrently.
