# TCDS ZSL2 V2.1.4 — Production-aligned performance + certification remediation

This package replaces the incomplete V2.1.3 remediation candidate. It is intentionally aligned to the live production history:

- synchronized historical migrations **001-008 are preserved byte-for-byte**;
- package-owned 009/010 are **not shipped** because production already has different applied 009/010 authority;
- all new work is forward-only migrations **011-015**;
- the Census/HUD normalizer is set-based rather than per-record SQL;
- keyset pagination and page transactions remain;
- expensive whole-source snapshot hashing is performed at source start/completion rather than every page;
- valid territorial HUD ZIP-county rows for FIPS 60/66/69/72/78 are retained as pending evidence, not fatal orphan parents;
- ZSL1 forward authority is the revocation-aware 13-release `CERTIFIED_RELEASE_VIEW` population under SHA `8565bda4f631f56e8f9aa1db6982144182a7076027cc77811e9398bc5a29a43c`;
- certification requires a signed ZSL2 authority decision and independent live population recheck;
- performance policy remains **P99 < 60 s/page** and **hard max < 120 s/page**.

REV9 performance evidence remains historical and failed. This package requires a new normalization/replay/certification run; it does not rewrite REV9 timing evidence or historical source bindings.

## Runtime order

1. Apply only forward migrations 011-015 after confirming production 009/010 are already present.
2. Verify the signed ZSL1 authority decision with Anthony Malone's pinned Ed25519 public key.
3. Run a new V2.1.4 normalization in staging with production-scale source releases.
4. Capture operation timings and query plans.
5. Require `NORMALIZE_PAGE` P99 < 60,000 ms and max < 120,000 ms.
6. Run deterministic replay, RBAC, activation/revocation, rollback and downstream contract checks.
7. Finalize certification only when all exact V2.1.4 required checks PASS.

`NOT_EXECUTED` is not PASS. Production activation is not authorized by this source package alone.
