# R1F V2 Production Configuration

Use only:
- `r1f-intelligence-policy-v2.example.json`
- `r1f-certification-policy-v2.example.json`
- `r1f-qa-fixtures-v2.examples.json`
- `r1f-e2e-scenarios-v2.example.json`

The E2E scenario file contains deployment-specific placeholders. Production QA must replace them with real succeeded R1D QA job UUIDs, a certified R1F V2 intelligence-policy UUID, controlled window times, and expected location fingerprints.

## Financial consumption certification additions

`r1f-certification-policy-v2.example.json` now also requires:

```json
{
  "minimum_provider_reconciled_cost_coverage_pct": 80.0,
  "minimum_provider_reconciliation_balance_pct": 100.0
}
```

For 50 E2E jobs this means at least 40 must be backed by reconciled Bright Data provider cost evidence when certifying this package.

## V2.2 production scraper financial mapping

Run `discover-production-scrapers.ts` against the exact `TCDS_BOT_CREATION` production checkout and database. It fails closed unless every current certified/effective R1D adapter is represented exactly once, then binds the result to the full Git commit SHA plus per-file SHA-256 values.

Use `r1f-production-scraper-financial-overrides.example.json` as the mapping shape. Every production scraper must resolve to either `ZONE_COST` with an authoritative Bright Data zone, or `COST_BREAKDOWN` with an authoritative dataset/collector identity. Registration and final certification reject incomplete mappings.
