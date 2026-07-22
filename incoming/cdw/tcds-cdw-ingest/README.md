# TCDS CDW Bright Data Enterprise Ingest

Production TypeScript ingestion worker for CDW using Bright Data dataset `gd_mou0eamd2mrvfw43gy`, with governed Web Unlocker fallback through `tcds_web_unlocker` and `tcds_premium_unlocker`.

## Seed URLs

- `https://www.cdw.com/category/phones-video-conferencing/cell-phones-accessories/cell-phones/?w=HA1&SortBy=PriceAsc&b=APL&filterClicked=Brand`
- `https://www.cdw.com/category/electronics/smartwatches/?w=EL`

## Controls

The package includes asynchronous dataset trigger/poll/download, bounded retries with exponential backoff and jitter, `Retry-After`, 408/425/429/5xx handling, real and logical 404 detection, standard-to-premium Unlocker escalation, empty-snapshot evidence capture, strict Zod validation with passthrough preservation, per-product PostgreSQL transactions, idempotent runs/captures/offers, database and local dead letters, and atomic DLQ replay.

CDW technical attributes are promoted into `retail.cdw_product_specifications` for searchable model, manufacturer, connectivity, certification, warranty, dimension, compatibility, and feature evidence. Parent product prices remain separate from child variants. Unknown availability is preserved rather than falsely converted to out-of-stock. Missing prices preserve product and inventory evidence while withholding offer promotion.

## Database objects

- `retail.cdw_product_parsed`
- `retail.cdw_product_images`
- `retail.cdw_product_categories`
- `retail.cdw_product_specifications`
- `retail.cdw_unlocker_evidence`

Validated records are promoted into the shared TCDS raw capture, canonical product, price history, inventory history, offer snapshot, current offer, data-quality, and dead-letter tables.

## CDW-specific data-quality controls

- `CDW_COLLECTION_SCOPE_MISMATCH`: the phone or smartwatch seed returned inventory outside governed mobile, wearable, or conferencing scope.
- `CDW_PRICE_FIELD_INVERSION`: `sale_price` exceeds `price`; the lowest valid observed price is selected and the anomaly is recorded.
- `CDW_CATEGORY_RESULT_NO_DISCOUNT`: equal regular and sale prices are not accepted as proof of a markdown.
- `CDW_PRICE_MISSING`: product and inventory evidence are preserved while price and offer promotion are withheld.

The supplied CDW URLs are category discovery URLs, not dedicated clearance feeds. Products must still pass post-ingestion discount validation before ERIP promotion.

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

Recommended production settings:

```env
CDW_UNLOCKER_MODE=fallback
CDW_UNLOCKER_ZONE_POLICY=standard_then_premium
```
