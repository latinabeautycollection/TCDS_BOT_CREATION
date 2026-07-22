# TCDS Dell Bright Data Enterprise Ingest

Production TypeScript ingestion worker for Dell using Bright Data dataset `gd_mkxzn676dd0x7mbcz`, with governed Web Unlocker fallback through `tcds_web_unlocker` and `tcds_premium_unlocker`.

## Seed URLs

- `https://www.dell.com/en-us/shop/deals/pc-laptop-deals`
- `https://www.dell.com/en-us/shop/deals/pc-accessories-deals`

Tracking parameters are intentionally removed from the governed defaults so duplicate URLs do not create duplicate collection work.

## Controls

The package includes asynchronous dataset trigger/poll/download, bounded retries with jitter, `Retry-After`, 408/425/429/5xx handling, real and logical 404 detection, standard-to-premium Unlocker escalation, empty-snapshot evidence capture, strict Zod validation with passthrough preservation, per-product PostgreSQL transactions, idempotent runs/captures/offers, database and local dead letters, and atomic DLQ replay.

Dell configuration variants are preserved in `variants`; the parent product price is never rewritten from a child configuration. Nullable variant attributes and `reviews: null` are normalized safely. Missing prices preserve product and inventory evidence while withholding price and offer promotion.

## Database objects

- `retail.dell_product_parsed`
- `retail.dell_product_images`
- `retail.dell_product_categories`
- `retail.dell_unlocker_evidence`

Validated records are promoted into the shared TCDS raw capture, canonical product, price history, inventory history, offer snapshot, current offer, data-quality, and dead-letter tables.

## Dell-specific data-quality controls

- `DELL_COLLECTION_SCOPE_MISMATCH`: a PC/laptop/accessories seed returned unrelated inventory.
- `DELL_PRICE_FIELD_INVERSION`: `sale_price` exceeds `price`; the lowest valid observed price is selected and the anomaly is recorded.
- `DELL_DEAL_PAGE_NO_DISCOUNT`: a deal-page result has equal regular and sale prices. Evidence is preserved, but TCDS must not assume the item is discounted.
- `DELL_PRICE_MISSING`: product and inventory evidence are preserved while price and offer promotion are withheld.
- Parent and child configuration evidence remain distinct; child configuration prices are never silently substituted for the selected SKU.

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
DELL_UNLOCKER_MODE=fallback
DELL_UNLOCKER_ZONE_POLICY=standard_then_premium
```
