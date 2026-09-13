# R1B V4 — Peer Review Remediation Map

## 1. `r1b_adapter_execution_ready()` wired into route authority
Implemented in `035d_r1b_scraper_authority_hardening_v4.sql`.

`r1b_route_is_current()` and `r1b_validate_route_approval()` now require
`r1b_adapter_execution_ready()`.

## 2. Scraper asset/contract included in route authority hashes
`r1b_adapter_authority_document()` now includes:

- scraper asset ID
- artifact authority type
- package-tree SHA
- entrypoint SHA
- asset evidence SHA
- contract ID/version
- contract SHA
- interface evidence SHA
- contract lifecycle status

`adapter_snapshot_hash` therefore binds these values and `route_authority_hash`
binds the resulting adapter snapshot hash.

## 3. No retrofit of scraper IDs onto certified adapter
`r1b_register_scraper_contract()` rejects already-certified adapters.

Use `clone-adapter-for-scraper-authority.ts` or
`create-adapter-for-scraper.ts` to create a new uncertified adapter version.

## 4. Package-tree attestation
`artifact-hash.ts`, `inventory-existing-scrapers.ts`,
`certify-adapter.ts`, and `attest-runtime-adapter.ts` use one deterministic
file/package-tree hashing algorithm.

## 5. Contract lifecycle + provenance
Added ARB process names and governed lifecycle:

`inventory_pending → contract_verified → qa_passed → certified_for_r1`

with terminal `blocked` / `retired`; `test_only` cannot promote.

Registration and lifecycle scripts create persistent `arb.process_runs`.

## 6. No empty-universe certification
Integration certification requires:

- `R1B_MIN_CERTIFIED_PRODUCTION >= 1`
- explicit non-empty `r1b_production_scraper_scope`
- every required production platform execution-ready
- latest integration certification CERTIFIED before main R1B certification

## 7. Evidence hashes recomputed
PostgreSQL triggers/functions recompute and compare:

- `verification_evidence_sha256`
- `interface_evidence_sha256`
- `contract_sha256`

Non-null alone is no longer sufficient.

## 8. DB ingest target validation
`r1b_validate_db_ingest_targets()` requires every declared target to:

- exist in PostgreSQL;
- be in the `retail` schema;
- be a shared canonical retail table or platform-specific retailer table.

Cross-platform parser destinations fail closed.
