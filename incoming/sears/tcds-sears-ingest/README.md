# TCDS Sears Bright Data Enterprise Ingest

Production TypeScript/Node.js ingestion package for Sears into the TCDS `retail` schema.

## Collection architecture

- Discovery: official first-party Sears product sitemap index
- Governed sitemap categories: Appliances, Electronics, and Tools
- PDP collection: standard Web Unlocker `tcds_web_unlocker`
- Dataset `gd_mm9b61afxxhdl6r18` is disabled because its PDP selector is obsolete
- Default QA target: 50 collected products from up to 500 broadly sampled URLs

## Governed discovery

The worker reads `https://www.sears.com/Sitemap_Index_Product_1.xml`, excludes
all marketplace (`MP`) sitemaps, and selects only Appliances, Electronics,
and Tools PDPs.

The source page is not treated as proof that a product is discounted. Regular and sale prices are preserved and validated after ingestion.

## Reliability controls

- Official sitemap discovery with gzip support
- Even sampling across complete category sitemaps to avoid stale-prefix bias
- Run resumption with `SEARS_RUN_ID`, preserving prior successful rows
- Canonical `/p-{item_id}` URL validation and deduplication
- Rendered PDP parsing for title, regular/sale prices, image, description,
  seller, item/model identifiers, availability, and specifications
- HTTP timeouts and `AbortController`
- Exponential backoff with jitter
- `Retry-After` support
- Retry handling for 408, 425, 429, 500, 502, 503, and 504
- Permanent 4xx classification
- Temporary snapshot-visibility 404 handling
- Target-page and logical HTTP-200 404 detection
- Standard-only Web Unlocker collection
- Per-product PostgreSQL transactions and rollback
- PostgreSQL and local forensic dead letters
- Atomic DLQ replay using `FOR UPDATE SKIP LOCKED`
- Unique auditable run keys
- Raw-capture, product, offer, and DLQ idempotency
- Structured JSON logs with secret redaction

## Sears-specific data-quality controls

- `SEARS_COLLECTION_SCOPE_MISMATCH`: result is outside electronics, computers, tools, or approved appliance scope.
- `SEARS_BRAND_MANUFACTURER_MISMATCH`: Sears reports itself as brand while the product title identifies another manufacturer, such as Samsung.
- `SEARS_PRICE_FIELD_INVERSION`: sale price exceeds regular price; lowest valid observed price is selected.
- `SEARS_SEED_RESULT_NO_DISCOUNT`: regular and sale prices are equal; seed origin does not prove markdown.
- `SEARS_PRICE_MISSING`: product and inventory evidence are retained, but offer promotion is withheld.
- `SEARS_OUT_OF_STOCK`: out-of-stock evidence is retained and the offer is marked unavailable.

Sears review feeds can contain hundreds of review and gallery images. `SEARS_MAX_IMAGES_PER_PRODUCT` defaults to 30 to prevent unbounded child-table growth while the complete original array remains in `raw_payload` and `parsed_payload`.

## Database objects

- `retail.sears_product_parsed`
- `retail.sears_product_images`
- `retail.sears_product_categories`
- `retail.sears_product_specifications`
- `retail.sears_unlocker_evidence`

The worker promotes validated records into the shared TCDS tables for raw captures, products, price history, inventory history, offer snapshots, current offers, data-quality events, and dead letters.

## Deployment

```bash
cp .env.example .env
# Populate DATABASE_URL and BRIGHT_DATA_API_TOKEN
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

## Production recommendation

Use `SEARS_UNLOCKER_MODE=always`, `SEARS_UNLOCKER_ZONE_POLICY=standard_only`,
and keep marketplace sitemap collection disabled unless separately governed.
