# ZSL2 V2.1.4 production-aligned performance + certification remediation

This release keeps synchronized historical migrations 001-008 byte-for-byte unchanged and deliberately omits package-owned 009/010 because production already owns different applied 009/010 hashes. All remediation begins with new forward migrations 011-014.

Performance policy remains unchanged: `NORMALIZE_PAGE` P99 < 60,000 ms and hard max < 120,000 ms. REV9 timing evidence remains historical and must not be rewritten.

The normalizer uses keyset pagination and set-based page operations. Census/HUD records are staged with typed UNNEST arrays, then locations, revisions, memberships, subtype rows, parent resolution, relationships and lineage are handled in bulk. The certified-record view itself is not indexed; migration 012 indexes its ZSL1 base tables.

Territorial HUD ZIP-county records for FIPS 60/66/69/72/78 with a missing county-equivalent are retained as pending evidence and lineage, not fatal orphan errors, provided the row came from the exact certified page and has a valid ZIP/GEOID. No county or relationship is fabricated.

ZSL1 authority is the current revocation-aware `CERTIFIED_RELEASE_VIEW` population under `8565bda4f631f56e8f9aa1db6982144182a7076027cc77811e9398bc5a29a43c`. A signed ZSL2 decision is verified externally with the governance public key, then the database independently recomputes the live 13-release population SHA before certification.

Final Freeze still requires a new measured staging replay, runtime query-plan evidence, RBAC, deterministic replay, rollback/activation and certification PASS. `NOT_EXECUTED` is not PASS.
