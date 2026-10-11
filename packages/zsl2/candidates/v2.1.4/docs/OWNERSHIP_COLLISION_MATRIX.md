# ZSL2 V2.1.2 Ownership / Collision Matrix

| Concept | Authoritative owner | ZSL2 access | V2.1.2 enforcement | Collision status |
|---|---|---|---|---|
| Canonical geography identity | ZSL2 | OWN | `zsl.locations`, subtype tables, run-scoped authority | No |
| Census state/county/place/ZCTA | ZSL2 | OWN | Census normalizers + lineage | No |
| HUD ZIP↔county / ZIP↔CBSA factual relationship | ZSL2 | OWN | `location_relationships` + run memberships | No |
| USPS operational ZIP authority | designated postal authority/ZSL3 validation path | PENDING/READ | HUD ZIP is `HUD_OBSERVED_PENDING_USPS`; no USPS elevation | No |
| Retailer/store identity | Retail/R domain | NONE | forbidden capability + foreign-schema DML revocation | No |
| Final search authorization | R1B | PROPOSE ONLY | `r1b_location_candidates` / sync proposals only | No |
| R1C request compilation | R1C | NONE | boundary guard + no write grant | No |
| R1D scheduling/execution | R1D | NONE | boundary guard + no write grant | No |
| Economic context | ZSL3 | READ SUPPORT | geography only | No |
| Freight economics | ZSL4 | READ SUPPORT | geography only | No |
| Acquisition tax | ZSL5 | READ SUPPORT | geography only | No |
| Retail offer intelligence | ZSL6 | NONE | foreign-schema write denial | No |
| Arbitrage decision/profit/capital | ARB | NONE | foreign-schema write denial | No |
| Purchase qualification | PQP | NONE | foreign-schema write denial | No |
| Checkout | CAX | NONE | foreign-schema write denial | No |
| Order lifecycle | ORL | NONE | foreign-schema write denial | No |
| Warehouse | Warehouse domain | NONE | foreign-schema write denial | No |
| Shipping/tracking | Shipping/Phase 3 Domain 6 | NONE | foreign-schema write denial | No |
| eBay lifecycle | ARB/eBay domains | NONE | no authority objects or grants | No |

Final collision status still requires runtime catalog/RBAC verification against the deployed database. `npm run verify:boundary` and the mandatory `cross_domain_write_denial` certification gate fail closed on observed foreign-domain DML grants.
