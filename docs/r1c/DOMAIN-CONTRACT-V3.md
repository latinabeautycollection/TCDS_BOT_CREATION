# R1C V3 Domain Contract

R1C V3 compiles only current `retail.effective_search_routes` backed by R1B V4 execution-ready scraper authority.

A compiled job binds:
- exact R1A revision hash
- exact R1B route authority hash
- exact R1B V4 certification run/package/evidence/view identity
- exact compile-profile version/hash
- exact scraper asset ID/package-tree or file SHA
- exact scraper contract ID/version/SHA
- exact adapter input/capability/certification identity
- exact R1C compiler authority SHA
- normalized job SHA
- adapter payload SHA
- compilation evidence SHA
- ARB process run/correlation identity

Certified contract `required_fields` are minimum mandatory fields. Profile requirements may add constraints only.

Optional geographic/result fields are emitted only when:
1. the certified input contract maps the field, and
2. the certified adapter capability explicitly supports it.

Supported transports:
- env
- argv
- json
- query
- hybrid

R1D may consume only `retail.effective_compiled_search_jobs`.
