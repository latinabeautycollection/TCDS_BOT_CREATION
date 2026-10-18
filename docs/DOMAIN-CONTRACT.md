# ZSL2 Domain Contract

ZSL2 is the canonical factual U.S. geography authority downstream of ZSL1 certified evidence.

**Owns:** canonical geography identity, Census state/county/place/ZCTA identities, HUD ZIP↔county and ZIP↔CBSA relationships, PostGIS points/geometry custody, geography lineage/conflicts, spatial query services, and factual candidates for downstream search authorization.

**Does not own:** retailer store identities, retailer search authorization, R1C request compilation, R1D scheduling, BUY/NO-BUY, capital, checkout, or warehouse authority.

Hard boundaries:
1. ZSL2 reads only `zsl.certified_release_records`.
2. USPS ZIP and Census ZCTA are never conflated.
3. HUD-observed ZIP values remain `PENDING_USPS_ZSL3` until USPS operational authority is ingested.
4. HUD CBSA codes may establish code identity but **not official CBSA names**; names remain pending an authoritative Census/OMB source.
5. ZSL2 never directly approves or mutates `retail.search_locations`. It emits signed proposals only.
6. Multi-parent geography is retained in `zsl.location_relationships`; no false single-parent hierarchy is invented.
