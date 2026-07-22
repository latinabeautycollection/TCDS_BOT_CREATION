# TCDS Crutchfield Bright Data Enterprise Ingest

Production TypeScript ingestion worker for Crutchfield using Bright Data dataset `gd_mos9yz5c2p9t04hfjd`, with governed Web Unlocker fallback through `tcds_web_unlocker` and `tcds_premium_unlocker`.

## Seed URLs

- `https://www.crutchfield.com/product/specials/default.aspx?offerid=155779&pg=2`
- `https://www.crutchfield.com/g_359650/In-ear-Earbud-Headphones.html`
- `https://www.crutchfield.com/g_124100/Noise-Canceling-Headphones.html`

## Controls

The package includes asynchronous dataset trigger/poll/download, bounded retries with jitter, `Retry-After`, 408/425/429/5xx handling, real and logical 404 detection, standard-to-premium Unlocker escalation, empty-snapshot evidence capture, strict Zod validation with passthrough preservation, per-product PostgreSQL transactions, idempotent runs/captures/offers, database and local dead letters, and atomic DLQ replay.

Crutchfield variant structures and variant prices are preserved in `variants`; the parent product price is never rewritten from a child option. Missing prices preserve the product and inventory evidence while withholding price and offer promotion and logging `CRUTCHFIELD_PRICE_MISSING`.

## Database objects

- `retail.crutchfield_product_parsed`
- `retail.crutchfield_product_images`
- `retail.crutchfield_product_categories`
- `retail.crutchfield_unlocker_evidence`

Validated records are promoted into the shared TCDS raw capture, canonical product, price history, inventory history, offer snapshot, current offer, data-quality, and dead-letter tables.

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
CRUTCHFIELD_UNLOCKER_MODE=fallback
CRUTCHFIELD_UNLOCKER_ZONE_POLICY=standard_then_premium
```
