# TCDS ZSL1 → ZSL5 National Tax Runtime Authority V1.2.0
## Green Tier 1 Final Freeze Candidate

This package is the final-freeze software/governance candidate for the TCDS national tax runtime. It supersedes the V1.1 adversarial-hardened runtime package for the ZSL5 V1.4 path while retaining ZSL5 V1.2 historical compatibility.

## Authority boundaries
- **ZSL1** owns official tax-source acquisition, immutable evidence, raw lineage, normalization, precedence, reconciliation, certification, state coverage, freshness evidence, and the atomic `US_NATIONAL_TAX_CONTENT` publication.
- **ZSL2** owns canonical geography/location identity.
- **ZSL5** consumes only certified ZSL1 content + active ZSL2 geography and owns tax determination, government fees, quote evidence, and the tax/government acquisition-cost authority contract.
- **ZSL6** is not created by this package. The current production repo/database has no ZSL6 runtime. This package exposes a read-only `zsl.zsl5_zsl6_acquisition_cost_authority_v14` contract for future ZSL6 acquisition-economics consumption.
- **R1A/R1F/ARB/PQP/CAX** are not mutated.

## Final governed scope
- 21 tax data families
- 51 jurisdictions (50 states + DC)
- 1,071 state/family certification cells
- 51 local/home-rule gates
- 51 address-resolution gates
- 10 governed TCDS tax categories: LAPTOPS, PHONES, NETWORKING, AUTOMOTIVE_TOOLS, GARDENING_TOOLS, GAME_CONSOLES, MUSIC_EQUIPMENT, DRONES, CAMERAS, ELECTRONICS

## V1.2.0 final-freeze remediations
1. Canonical quote runtime now consumes the actual 21-family schema field names instead of ad-hoc aliases.
2. `effective_to` is treated as exclusive: `[effective_from,effective_to)`.
3. State-code format is explicitly constrained on V1.4 runtime surfaces.
4. Raw-record deduplication is immutable; existing rows are verified, never updated.
5. Canonical ingest now supplies all mandatory lineage/version columns required by `zsl_tax_acq.canonical_records`.
6. Release-membership conflicts are verified rather than silently ignored.
7. Jurisdiction resolution implements DIRECT_TAX_ADDRESS_ID → ZIP9 → ADDRESS_RULE → DIRECT_ZSL2_ID → AUTHORITATIVE_POLYGON → ZIP5 → STATEWIDE → fail closed.
8. Seller collection/marketplace logic uses canonical enum semantics and fails closed on UNKNOWN/unmodeled conditions.
9. Seller tax elections must have explicit LOCAL rate-override scope and are actually applied to calculation.
10. Holiday, mandatory fee, tax-credit, allocation, cap, and rounding fields align with canonical schemas.
11. Unsupported bundle/rate/holiday/legal semantics fail closed instead of guessing.
12. Exact BigInt/scaled-decimal money math supports deterministic rounding modes.
13. A V1.4 canonical-payload violation view blocks final-freeze activation.
14. Final-freeze activation requires national coverage, freshness, security, categories, golden/adversarial results, and valid bindings.
15. Read-only ZSL5→ZSL6 acquisition-cost authority contract added without creating ZSL6 ownership.

## Migration order
Production baseline → 042a-d → 043/043a-c → 044a-b → 045/045a → 046a-c → **047a-c**.

## Validation performed
- Root TypeScript build: PASS
- Root automated tests: 21/21 PASS
- Static cross-domain/package validation: PASS
- Acquisition TypeScript syntax scan: 23/23 PASS
- Acquisition dependency-aware install/typecheck: **NOT COMPLETED in this environment (npm install timed out)**
- Current production repo cross-check: `main` observed at `ef985e28f41a56b5b5d25252aacdb1ab456888b0`; no 042+ migrations or `apps/zsl-tax-intelligence` path present at review time.

## Certification truth
**Software/governance final-freeze candidate:** PASS.

**Production national tax authority:** NOT YET CERTIFIED. Production certification still requires live source population, 1,071/1,071 certified cells, 51/51 local gates, 51/51 resolution gates, current freshness, independent golden/adversarial evidence, staging migration execution, acquisition-tool dependency-aware validation, replay, rollback, performance testing, and authorized activation.
