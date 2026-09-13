# R1B V4 Scraper Authority Hardening

This hardening layer closes the final execution-authority gap between R1B and the existing tested retail scrapers.

## Non-negotiable authority chain

`effective_search_routes` is executable only when:

1. the R1A revision is current;
2. the platform/source/location are current;
3. the adapter is cryptographically certified;
4. the adapter points to one exact verified scraper asset;
5. the adapter points to one exact `certified_for_r1` scraper contract;
6. asset evidence and contract evidence hashes reproduce;
7. route `adapter_snapshot_hash` reproduces from an authority document containing the scraper asset/contract hashes;
8. runtime attestation proves the deployed file or package tree matches the certified scraper asset.

## Existing certified adapters

Do not attach `scraper_asset_id` or `scraper_contract_id` to an existing `certified_dynamic_search` adapter.

Create a new adapter version:

```text
adapter v1 (old certification)
      ↓ do not mutate
adapter v2 (uncertified)
      ↓ attach exact scraper asset
      ↓ register/verify/QA/certify exact scraper contract
      ↓ certify adapter
      ↓ recreate/reapprove routes
```

This preserves immutable evidence.

## Artifact authority

Single-file workers use `file` attestation.

Package workers use deterministic `package_tree` attestation. The tree hash excludes only generated/non-source directories:

- `.git`
- `node_modules`
- `dist`
- `build`
- `coverage`

The same algorithm is used at inventory and runtime.

## Contract lifecycle

```text
inventory_pending
  → contract_verified
  → qa_passed
  → certified_for_r1
  → blocked / retired
```

`test_only` can never transition to production certification.

Blocked contracts cannot be reactivated; register a new contract version.

## DB ingest targets

Every declared target must:

- exist in PostgreSQL (`to_regclass`);
- be in the `retail` schema;
- be a canonical shared retail table, or
- have a retailer/platform-specific table prefix.

Cross-retailer parser destinations fail closed.

## Production certification

Certification requires a non-empty explicit `r1b_production_scraper_scope`.

Every required platform must have an execution-ready adapter.
