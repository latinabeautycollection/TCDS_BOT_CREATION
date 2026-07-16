# TCDS Staples Bright Data Enterprise Ingest

Production TypeScript worker for Bright Data dataset `gd_mkpali8c17mjkucviv`, normalized into the TCDS `retail` schema.

## Collection architecture

- Primary: Bright Data asynchronous dataset trigger using configured Staples category/deal URLs.
- Recovery: `tcds_web_unlocker`, escalating to `tcds_premium_unlocker` when configured.
- Persistence: raw capture, Staples parsed row, normalized product, price history, inventory history, offer snapshots, current offer, child image/category tables, and DLQ.
- Idempotency: payload and offer hashes plus platform/product unique constraints.

## Resilience

- Exponential backoff with jitter and `Retry-After` support.
- Retry classification for 408, 425, 429, 500, 502, 503, and 504.
- AbortController request timeouts and bounded snapshot polling.
- Transaction per product, rollback on any partial failure.
- PostgreSQL and filesystem dead-letter evidence.
- Controlled DLQ replay.
- Credential-redacted structured logs.

## Install

```bash
cp .env.example .env
npm ci
npm run migrate
npm run typecheck
npm test
npm run build
npm start
```

## Web Unlocker modes

- `disabled`: dataset only.
- `fallback`: use Unlocker only after validation or ingest failure. Recommended.
- `always`: retain unlocked page evidence for every valid record.

## Source identity

Every Staples-specific parsed row stores `source_platform='staples'`, `source_dataset='brightdata_staples'`, and `parser_version='brightdata_staples_v1'`. The shared platform foreign key remains the authoritative relational identity.

## DLQ replay

```bash
npm run dlq:replay
```
