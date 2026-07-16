# TCDS Target Bright Data + Web Unlocker Ingest

Enterprise Target collector for dataset `gd_ltppk5mx2lp0v1k0vo`.

## Collection strategy
- Primary: Bright Data Target keyword discovery (`discover_new`, `discover_by=keywords`).
- Recovery/evidence: Bright Data Web Unlocker API through `tcds_web_unlocker`, then `tcds_premium_unlocker` when configured.
- Web Unlocker is **not** called for every product by default. `TARGET_UNLOCKER_MODE=fallback` contains cost and only invokes it when a dataset record is invalid or fails transactional ingestion.
- `TARGET_UNLOCKER_MODE=always` captures HTML evidence for every valid Target URL, which can materially increase cost.

## Data flow
1. Create `retail.collection_runs` audit record.
2. Trigger async Target dataset discovery for headphones, computers, laptops and smart watches.
3. Poll `/datasets/v3/progress/{snapshot_id}` using bounded exponential retry with jitter and `Retry-After` support.
4. Download ready snapshot from `/datasets/v3/snapshot/{snapshot_id}`.
5. Validate and normalize Target records.
6. Commit raw capture, Target parsed row, canonical product, price, inventory, offer and current-offer records atomically.
7. Persist product images and specifications as child rows.
8. Dead-letter bad records to PostgreSQL and local JSON.
9. On eligible failures, call Web Unlocker and retain response evidence plus any Product JSON-LD found.

## Setup
```bash
cp .env.example .env
npm ci
npm run migrate
npm run typecheck
npm test
npm run build
npm start
```

## Important deployment controls
- Store the Bright Data token in a secret manager, never source control.
- Use one scheduler instance or a distributed lock.
- Keep fallback mode enabled first; promote specific hard Target URLs to premium only after reviewing standard-zone outcomes and costs.
- Run `npm run dlq:replay` from a controlled worker schedule.
