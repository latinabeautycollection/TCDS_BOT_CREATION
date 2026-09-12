# R1B V3 Domain Contract

## Authority
R1A answers WHAT.
R1B answers WHERE / THROUGH WHAT APPROVED RETAIL PATH.
R1C/R1D compile/schedule/spend/dispatch.
R1E validates returned items.
ARB/ERIP own economics, capital and purchase authority.

## R1A/R1B conflict remediation
R1B V3 does not use `R1A.desired_source_types` as a hard runtime gate.
Source-type authority is R1B-owned:
1. selected approved `platform_collection_sources` row;
2. certified adapter `supported_source_types`;
3. immutable route snapshot / route authority hash.

`allowed_conditions` and `desired_discount_signals` are carried through as R1A product/search intent.

## Store identity
Store IDs are retailer scoped:
`UNIQUE(platform_id, retailer_store_id)` for `location_type='store'`.

A Best Buy store ID can never be treated as a Walmart/Lowe's/etc. store.

## Geography
Hierarchy uses `parent_location_id`:
NATIONAL -> REGION/STATE -> METRO -> POSTAL -> STORE.
This is the foundation for R1D geographic escalation across the continental USA.

## Adapter certification
Certification binds:
- platform + adapter type/code/version
- implementation path
- implementation SHA-256
- Git commit when available
- input contract SHA-256
- capability SHA-256
- QA evidence SHA-256

Certified versions are immutable. Code/contract/capability changes require a new version.

## Route evidence
Each route stores immutable:
- R1A revision SHA
- platform snapshot/hash
- source snapshot/hash
- adapter snapshot/hash
- optional location snapshot/hash
- composite `route_authority_hash`

Any current-authority drift removes the route from `effective_search_routes` immediately.


V3 requires exact R1A certification binding and runtime adapter artifact attestation before R1C execution.
