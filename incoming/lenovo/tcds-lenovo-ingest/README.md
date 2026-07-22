# TCDS Lenovo Bright Data Enterprise Ingest

Production TypeScript ingestion worker for Lenovo using Bright Data dataset `gd_mlf1fywqjstgnzsxc`, with governed Web Unlocker fallback through `tcds_web_unlocker` and `tcds_premium_unlocker`.

## Seed URLs

- `https://www.lenovo.com/us/en/d/deals/laptops/?sortBy=priceUp`
- `https://www.lenovo.com/us/en/d/deals/gaming/?sortBy=priceUp`

Tracking parameters are intentionally removed from the governed defaults so duplicate URLs do not create duplicate collection work.

## Controls

The package includes asynchronous dataset trigger/poll/download, bounded retries with jitter, `Retry-After`, 408/425/429/5xx handling, real and logical 404 detection, standard-to-premium Unlocker escalation, empty-snapshot evidence capture, strict Zod validation with passthrough preservation, per-product PostgreSQL transactions, idempotent runs/captures/offers, database and local dead letters, and atomic DLQ replay.

Lenovo configuration variants are preserved in `variants`; the parent product price is never rewritten from a child configuration. Nullable ratings, GTINs, review arrays, and variant fields are normalized safely. Lenovo category labels such as `Cases & Bags` are retained as source evidence without being trusted as the canonical manufacturer. Missing prices preserve product and inventory evidence while withholding price and offer promotion.

## Database objects

- `retail.lenovo_product_parsed`
- `retail.lenovo_product_images`
- `retail.lenovo_product_categories`
- `retail.lenovo_unlocker_evidence`

Validated records are promoted into the shared TCDS raw capture, canonical product, price history, inventory history, offer snapshot, current offer, data-quality, and dead-letter tables.

## Lenovo-specific data-quality controls

- `LENOVO_COLLECTION_SCOPE_MISMATCH`: a governed laptop or gaming seed returned inventory outside Lenovo computing, gaming, or accessory scope.
- `LENOVO_PRICE_FIELD_INVERSION`: `sale_price` exceeds `price`; the lowest valid observed price is selected and the anomaly is recorded.
- `LENOVO_DEAL_PAGE_NO_DISCOUNT`: a deal-page result has equal regular and sale prices. Evidence is preserved, but TCDS must not assume the item is discounted.
- `LENOVO_PRICE_MISSING`: product and inventory evidence are preserved while price and offer promotion are withheld.
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
LENOVO_UNLOCKER_MODE=fallback
LENOVO_UNLOCKER_ZONE_POLICY=standard_then_premium
```
