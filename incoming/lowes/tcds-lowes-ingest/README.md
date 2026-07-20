# TCDS Lowe's Bright Data Enterprise Ingest

Canonical Lowe's category-to-PDP ingestion worker for the TCDS `retail` schema.

## Collection flow

1. Request configured Lowe's category pages through the standard Bright Data Web Unlocker.
2. Use Unlocker `format=json`, US geolocation, and inspect the inner target `status_code`.
3. Retry wrapped target failures such as `502`, empty bodies, and adaptive throttling.
4. Extract, canonicalize, and deduplicate Lowe's `/pd/<slug>/<id>` URLs.
5. Trigger dataset `gd_lnvl79pfftqh18u2o` with one result allowed per PDP input.
6. Validate records and promote accepted products, prices, inventory, offers, images, and categories.
7. Account for provider errors and omitted inputs in collection-run totals and dead letters.

The category discovery limit and PDP detail limit are separate. Keep
`LOWES_DETAIL_LIMIT_PER_INPUT=1` when increasing discovery volume.

## Reliability and data controls

- standard unlocker only by default; no automatic premium escalation
- inner target-status validation for Unlocker JSON responses
- canonical `marketplace_pn` product identity
- strict Zod parsing with null arrays normalized to empty arrays
- deterministic JSONB serialization
- lowest valid observed price as effective price
- normalized regular, sale, and effective price relationships
- truthful `completed`, `partial`, and `failed` run accounting
- provider failures stored as non-retryable dead letters
- transaction rollback and local forensic DLQ for ingestion failures

## Commands

```bash
npm ci
npm run typecheck
npm test
npm run build
npm run migrate
npm run dev
```

Required environment variables are documented in `.env.example`. The shared
server environment uses `BRIGHTDATA_TOKEN`; export it as
`BRIGHT_DATA_API_TOKEN` before running this package.
