# ZSL2 V2.1.4 production-aligned hardening report

## Resolved defects

1. **Production migration collision:** package-owned 009/010 are removed. Historical 001-008 are copied byte-for-byte from the synchronized baseline. New remediation begins at 011 and is forward-only.
2. **Normalizer round-trip explosion:** Census/HUD page processing uses typed staging + set-based location/revision/membership/subtype/parent/relationship/lineage operations. No per-record SQL write loop remains on the main page path.
3. **Repeated full source scans:** immutable-source snapshot hashing is validated at source start and source completion rather than once per page.
4. **Certified release fetch path:** new indexes target the base ZSL1 tables behind `zsl.certified_release_records`; the view itself is not indexed.
5. **Territorial certification blocker:** valid FIPS 60/66/69/72/78 HUD ZIP-county records with unavailable county-equivalent authority are retained in `zsl2_territorial_pending_evidence_v214` with exact source lineage. No county or relationship is fabricated.
6. **ZSL1 authority mismatch:** the forward authority is SHA `8565bda4f631f56e8f9aa1db6982144182a7076027cc77811e9398bc5a29a43c` under the revocation-aware `CERTIFIED_RELEASE_VIEW` model. Certification preparation verifies an Ed25519-signed ZSL2 authority decision, pins the governance public key SHA, and independently recomputes the live 13-release population SHA.
7. **Certification scope:** V2.1.4 uses an exact evaluation/check registry and requires source, territorial, ZSL1-authority, replay, performance, RBAC, activation, rollback and downstream-contract checks before `CERTIFIED`.

## Performance policy

Unchanged:
- `NORMALIZE_PAGE` P99 < 60,000 ms
- hard max < 120,000 ms

REV9's 28-44 minute page timings remain historical failed evidence and are not rewritten.

## Source validation

- TypeScript no-emit: PASS with temporary validation-only type shims
- TypeScript build: PASS with temporary validation-only type shims
- Automated source/static tests: 40/40 PASS
- Source manifest: PASS
- Historical migrations 001-008: byte-for-byte match synchronized baseline
- Conflicting package migrations 009/010: not shipped

## Runtime state

PostgreSQL migration execution, production-scale replay, query-plan measurement, RBAC, activation/revocation and performance certification remain `NOT_EXECUTED`. The source package does not claim Final Freeze until those execute successfully.
