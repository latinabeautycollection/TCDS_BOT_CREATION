# TCDS Sam's Club Bright Data Enterprise Ingest

Production TypeScript ingestion worker that discovers Sam's Club PDP URLs through the standard Web Unlocker and extracts product details with Bright Data dataset `gd_mljead55j96getj3h`.

Discovery and detail limits are separate: `SAMSCLUB_LIMIT_PER_INPUT` caps globally discovered PDPs, while `SAMSCLUB_DETAIL_LIMIT_PER_INPUT=1` prevents variant expansion from overstating collection totals.

## Governed seeds

- `https://www.samsclub.com/browse/tablets-accessories/2350101?mid=2026_evergreen_computers_tablets_hubspoke`
- `https://www.samsclub.com/cp/electronics/1086?mid=2025_globalnav_electronic_shopall`
- `https://www.samsclub.com/browse/televisions-and-tv-accessories/1087`

These are discount-oriented collection sources. A source URL does not prove every returned record is relevant or discounted; the worker preserves source truth and emits data-quality evidence for downstream TCDS discount and Prong 2 qualification.

## Processing flow

1. Validate all configured seeds as HTTPS Sam's Club URLs.
2. Discover canonical PDP URLs from category hydration JSON through `tcds_web_unlocker`.
3. Create a governed `retail.collection_runs` row for the discovered PDP inputs.
4. Trigger the asynchronous Bright Data dataset with one record per PDP.
4. Poll snapshot progress with bounded timeout and delayed-snapshot 404 tolerance.
5. Download JSON or JSONL data.
6. Validate and normalize each record with Zod, including explicit `null` arrays.
7. Insert each product transactionally into raw capture, Sam's Club parsed, canonical product, price, inventory, offer, image, and category tables.
8. Reject missing prices and normalize inverted price fields before canonical promotion.
9. Write failed records to PostgreSQL and local forensic dead letters.
10. Account for provider errors and omitted inputs as skipped records in partial runs.
11. Replay retryable DLQ entries through an atomic claim worker using `FOR UPDATE SKIP LOCKED`.

## Reliability controls

- Retryable statuses: 408, 425, 429, 500, 502, 503, 504.
- Exponential backoff with jitter and `Retry-After` support.
- `AbortController` request timeout.
- Permanent 4xx classification and bounded attempts.
- Bright Data snapshot progress, terminal-state, and maximum-wait enforcement.
- Real HTTP 404 and logical HTTP-200 page-not-found detection.
- Standard Web Unlocker discovery with retries for HTTP-200 rate-limit bodies.
- Empty-snapshot evidence validation.
- Per-product PostgreSQL transactions and rollback.
- Deterministic raw capture, product, offer, run, and DLQ idempotency.
- Structured logging and secret redaction.
- Database and local JSON dead-letter evidence.
- DLQ backoff capped at 24 hours and abandonment after repeated failures.

## Sam's Club-specific protections

### Null collections

Sam's Club may return `variant_attributes`, `variants`, images, categories, reviews, or target countries as `null`. They are normalized to empty arrays rather than incorrectly dead-lettered.

### Missing price

A product with no usable `price` or `sale_price` is rejected to the dead-letter queue so canonical products and offers remain price-complete.

### Price field inversion

When `sale_price` exceeds `price`, the worker uses the lowest valid observed price and records `SAMSCLUB_PRICE_FIELD_INVERSION` with full evidence.

### Collection-scope mismatch

The supplied example returns a breakroom snack from PC/electronics/printer deal seeds. The worker preserves the record but records `SAMSCLUB_COLLECTION_SCOPE_MISMATCH` and adds `collection_scope_match` to price and offer metadata so ERIP can exclude it.

## Database objects

The migration creates:

- `retail.samsclub_product_parsed`
- `retail.samsclub_product_images`
- `retail.samsclub_product_categories`
- `retail.samsclub_unlocker_evidence`

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
SAMSCLUB_UNLOCKER_MODE=fallback
SAMSCLUB_UNLOCKER_ZONE_POLICY=standard_only
```

## DLQ replay

```bash
npm run dlq:replay
```

Run one or more replay workers safely; atomic claiming and row locking prevent the same dead letter from being processed concurrently.
