# TCDS Newegg Bright Data Enterprise Ingest

Production TypeScript worker for Bright Data Newegg dataset `gd_mkcnpcq825jb5uiuna`.

## Collection flow

1. Fetch Newegg category pages through the standard Web Unlocker zone.
2. Extract, validate, canonicalize, and deduplicate Newegg `/p/<product-id>` URLs. Navigation links such as `/p/pl` are rejected.
3. Stop at the global discovery limit, 50 by default.
4. Trigger the Bright Data product dataset with PDP URLs and `limit_per_input: 1`.
5. Validate each dataset row and require a usable price before canonical promotion.
6. Atomically write raw captures, parsed rows, canonical variant-safe products, inventory, price history, offers, images, and categories.
7. Account for provider errors and silently omitted inputs so runs finish truthfully as `completed`, `partial`, or `failed`.

The default flow uses `tcds_web_unlocker` only. Premium escalation is disabled.

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

## Price handling

- Equal `price` and `sale_price` values are stored as one regular/effective price, not a false discount.
- When both fields differ, the higher value is regular and the lower value is sale/effective.
- A single observed price becomes regular/effective.
- Rows without a usable price are dead-lettered and never promoted as incomplete offers.

## DLQ replay

```bash
npm run dlq:replay
```

DLQ claims use a transactional `FOR UPDATE SKIP LOCKED` transition before processing.
