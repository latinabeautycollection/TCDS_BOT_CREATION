# R1F V2.2 Corrected Candidate

This candidate incorporates the pre-install financial-consumption corrections requested on 2026-09-21.

## Corrections

- `r1f_record_brightdata_cost_breakdown_response` excludes `total` from date parsing and verifies each aggregate resource amount against exact PostgreSQL `NUMERIC(18,8)` daily sums.
- `web_apis` dataset/day reconciliation proves complete successful R1D execution coverage before allocating provider cost. These facts use `cost_basis=allocated_provider`, not direct job cost.
- `/zone/cost` accepts legacy `ID` payloads and the actual single dynamic account-key shape, including `hl_ae30ad2f`.
- Scraper discovery and certification derive the required scope from current effective compiled R1D adapters with current certified dispatch bindings. No numeric scraper count is hard-coded.
- `ws_api_snaps` requires a unique snapshot receipt, one binding, `DIRECT_RESOURCE`, and direct cost attribution.

## Validation

- TypeScript compilation: passed for all modified scripts.
- Provider parser runtime tests: 4 passed, 0 failed.
- JSON validation: passed.
- PostgreSQL migration dry run and database-backed adversarial tests remain mandatory on the acquisition server before installation or certification.
