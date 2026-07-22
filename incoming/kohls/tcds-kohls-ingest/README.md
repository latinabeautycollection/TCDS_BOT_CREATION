# TCDS Kohl's Bright Data Enterprise Ingest

Production TypeScript ingestion worker for Kohl's using Bright Data dataset `gd_mlji2hi729x1g0vg4i`, with governed Web Unlocker fallback through `tcds_web_unlocker` and `tcds_premium_unlocker`.

## Seed URLs

- `https://www.kohls.com/catalog/electronics.jsp?CN=Department:Electronics&BST=7749546&cc=for_thehome-TN2.0-S-electronics`
- `https://www.kohls.com/catalog/small-appliances-kitchen-dining.jsp?CN=Category:Small%20Appliances+Department:Kitchen%20%26%20Dining&cc=for_thehome-TN3.0-S-kitchenappliances`

## Controls

The package includes asynchronous dataset trigger/poll/download, bounded retries with jitter, `Retry-After`, 408/425/429/5xx handling, real and logical 404 detection, standard-to-premium Unlocker escalation, empty-snapshot evidence capture, strict Zod validation with passthrough preservation, per-product PostgreSQL transactions, idempotent runs/captures/offers, database and local dead letters, and atomic DLQ replay.

Kohl's variant structures and variant prices are preserved in `variants`; the parent product price is never rewritten from a child option. Missing prices preserve the product and inventory evidence while withholding price and offer promotion and logging `KOHLS_PRICE_MISSING`.

## Database objects

- `retail.kohls_product_parsed`
- `retail.kohls_product_images`
- `retail.kohls_product_categories`
- `retail.kohls_unlocker_evidence`

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
KOHLS_UNLOCKER_MODE=fallback
KOHLS_UNLOCKER_ZONE_POLICY=standard_then_premium
```

## Kohl's-specific data quality controls

- `KOHLS_COLLECTION_SCOPE_MISMATCH`: the electronics/small-appliance seeds returned an unrelated catalog item. The evidence is preserved, but downstream ERIP must not treat it as a qualified target-category offer.
- `KOHLS_PRICE_FIELD_INVERSION`: `sale_price` exceeds `price`; the engine selects the lowest valid observed price and records the anomaly.
- `KOHLS_PRICE_MISSING`: the product and inventory evidence are preserved while price and offer promotion are withheld.
- Parent and child variant evidence remain distinct; child option prices are retained in `variants` and never silently substituted for the selected SKU's parent price.
