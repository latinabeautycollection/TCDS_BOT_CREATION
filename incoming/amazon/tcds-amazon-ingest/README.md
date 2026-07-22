# TCDS Amazon Bright Data Enterprise Ingest

Production TypeScript ingestion worker for Amazon keyword discovery using Bright Data dataset `gd_l7q7dkf244hwjntr0`, with controlled Web Unlocker fallback through `tcds_web_unlocker` and `tcds_premium_unlocker`.

## Discovery inputs

- `smart watch`
- `laptops`
- `iphone`
- Optional ZIP code through `AMAZON_ZIPCODE`

The trigger preserves Bright Data's Amazon discovery contract: `type=discover_new`, `discover_by=keyword`, keyword/ZIP input objects, `include_errors=true`, and a configurable `limit_per_input` up to 1000.

## Amazon-specific controls

- ASIN is the canonical platform product key.
- Parent ASIN is preserved for variation-family grouping.
- Keyword-scope mismatches are retained but flagged `AMAZON_KEYWORD_SCOPE_MISMATCH`.
- Sponsored results are retained but flagged `AMAZON_SPONSORED_RESULT`.
- Frequently returned products are flagged `AMAZON_FREQUENTLY_RETURNED_ITEM`.
- Missing prices create `AMAZON_PRICE_MISSING`; product and inventory evidence remain stored while offer promotion is withheld.
- `Currently unavailable` is classified out-of-stock before generic `available` matching.
- Buy-box seller, seller count, ships-from, Prime, Amazon Choice, coupon, rankings, bought-past-month, quantity, and return-risk evidence are retained.
- `initial_price`, `final_price`, and `final_price_high` are parsed independently; the lowest valid observed value is used provisionally without claiming a discount.

## Database objects

- `retail.amazon_product_parsed`
- `retail.amazon_product_images`
- `retail.amazon_product_categories`
- `retail.amazon_product_details`
- `retail.amazon_unlocker_evidence`

Records are also promoted transactionally into the shared TCDS raw capture, canonical product, price history, inventory history, offer snapshot, current offer, data-quality, and dead-letter tables.

## Reliability controls

The package includes bounded timeouts, `AbortController`, exponential backoff with jitter, `Retry-After`, HTTP 408/425/429/500/502/503/504 recovery, permanent 4xx classification, delayed snapshot-visibility 404 handling, logical HTTP-200 404 detection, JSON/JSONL snapshot support, per-product transactions, local and PostgreSQL DLQs, atomic replay claims with `FOR UPDATE SKIP LOCKED`, deterministic hourly run keys, structured logging, and secret redaction.

## Deployment

```bash
cp .env.example .env
# populate DATABASE_URL and BRIGHT_DATA_API_TOKEN
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
AMAZON_UNLOCKER_MODE=fallback
AMAZON_UNLOCKER_ZONE_POLICY=standard_then_premium
AMAZON_KEYWORDS=smart watch,laptops,iphone
AMAZON_ZIPCODE=
```

`fallback` prevents Web Unlocker from running on every successful Amazon result and protects the TCDS daily scraping budget.
