# ZSL2 V2.1.2 — 127-Point Green Tier 1 Remediation Matrix

The user request referred to 105 points, but the supplied adversarial recommendation contains **127 numbered controls**. This matrix tracks all 127. `SOURCE IMPLEMENTED` means the candidate contains an implementation/control. `RUNTIME REQUIRED` means the candidate intentionally fails Final Freeze until real PostgreSQL/PostGIS/staging evidence is supplied.

| # | Remediation / control | Status |
|---:|---|---|
| 1 | Reviewer roles are encoded as review doctrine; package adds explicit runtime, performance, RBAC, replay and boundary gates. | SOURCE IMPLEMENTED |
| 2 | Final status is DB-computed and cannot be inferred from source tests alone. | SOURCE IMPLEMENTED |
| 3 | Boundary module, RBAC revocations and ownership matrix preserve factual-geography scope. | SOURCE IMPLEMENTED |
| 4 | One-owner doctrine enforced by schema boundaries and foreign-domain DML denial. | SOURCE IMPLEMENTED |
| 5 | ZIP/ZCTA canonical keys and types remain distinct; mandatory certification check added. | SOURCE IMPLEMENTED |
| 6 | HUD postal identity remains pending USPS authority. | SOURCE IMPLEMENTED |
| 7 | HUD CBSA code-only identities retain NULL official_name / PENDING_CENSUS_OMB. | SOURCE IMPLEMENTED |
| 8 | Territorial records preserved; certification rejects non-Census county fabrication. | SOURCE IMPLEMENTED |
| 9 | No single-parent simplification; multi-parent source pair counts are reconciled. | SOURCE IMPLEMENTED |
| 10 | V2.1 external functions/views retained; downstream contract gate added. | SOURCE IMPLEMENTED |
| 11 | New runs require exact six-source binding file; certification rejects missing/unexpected sources. | SOURCE IMPLEMENTED |
| 12 | Durable source checkpoints remain exact release/ingest-bound. | SOURCE IMPLEMENTED |
| 13 | Page transactions/checkpoint events and integration runbook define crash-boundary tests. | RUNTIME REQUIRED |
| 14 | Keyset pagination uses exact (ordinal,record_id) ordering and bigint-safe cursors. | SOURCE IMPLEMENTED |
| 15 | Immutable source snapshot count/range/hash is captured and revalidated. | SOURCE IMPLEMENTED |
| 16 | Bigint/ordinal values use string/BigInt; HUD ratios use exact decimal strings/PostgreSQL numeric. | SOURCE IMPLEMENTED |
| 17 | HUD stage is TEMP ON COMMIT DELETE ROWS and page-transaction scoped. | SOURCE IMPLEMENTED |
| 18 | JSONB stage loading replaced by typed UNNEST; COPY comparison remains runtime benchmark requirement. | RUNTIME REQUIRED |
| 19 | Relationship drift is explicitly detected and fatal instead of silent ON CONFLICT loss. | SOURCE IMPLEMENTED |
| 20 | Each staged raw_record_id must resolve to exactly one intended relationship; lineage separately preserves every source record. | SOURCE IMPLEMENTED |
| 21 | Authority uniqueness remains release-scoped; ingest provenance is retained in memberships and lineage. | SOURCE IMPLEMENTED |
| 22 | Row ratios are exact numeric, NULL distinct from zero, and range checked. | SOURCE IMPLEMENTED |
| 23 | Component aggregate targets are 0/1; total target is 1 within policy tolerance. | SOURCE IMPLEMENTED |
| 24 | HUD ratio groups are relationship_type + source_release + postal child; runtime fixtures must validate HUD source semantics. | SOURCE IMPLEMENTED |
| 25 | Zero-component counts are persisted in certification evidence. | SOURCE IMPLEMENTED |
| 26 | 99999 is stored as outside-CBSA fact and never as US:CBSA:99999. | SOURCE IMPLEMENTED |
| 27 | Canonical identity SHA is stable; mutable display/revision attributes are separated. | SOURCE IMPLEMENTED |
| 28 | Subtype projections update mutable fields while guarding immutable identity keys. | SOURCE IMPLEMENTED |
| 29 | Remaining row-oriented work is explicitly included in query-plan/performance certification. | RUNTIME REQUIRED |
| 30 | Runtime SQL/runbook require EXPLAIN ANALYZE BUFFERS WAL evidence. | RUNTIME REQUIRED |
| 31 | Critical keyset/relationship/lineage/checkpoint indexes are installed and runtime-plan verified. | RUNTIME REQUIRED |
| 32 | Index write amplification is a required runtime review, not assumed from static index count. | RUNTIME REQUIRED |
| 33 | Performance attestation requires production-scale workload. | RUNTIME REQUIRED |
| 34 | Performance measurement table and attestation capture timing/resource evidence. | RUNTIME REQUIRED |
| 35 | Mandatory thresholds: P99 <60s and max <120s. | RUNTIME REQUIRED |
| 36 | Source page sizes are policy-driven and benchmark matrix is required. | RUNTIME REQUIRED |
| 37 | No global timeout workaround is introduced; runtime review searches for timeout overrides. | SOURCE IMPLEMENTED |
| 38 | Every normalization page is a bounded transaction. | SOURCE IMPLEMENTED |
| 39 | Crash/resume/connection-loss proof is a PostgreSQL integration gate. | RUNTIME REQUIRED |
| 40 | Same run/source uses transaction advisory lock; multi-run behavior must be integration-tested. | RUNTIME REQUIRED |
| 41 | Lock is acquired before checkpoint FOR UPDATE/page read, closing same-checkpoint race. | SOURCE IMPLEMENTED |
| 42 | Certification requires 6/6 complete plus all mandatory evidence. | RUNTIME REQUIRED |
| 43 | Controlled activation requires CERTIFIED authority and fresh bindings/snapshots. | RUNTIME REQUIRED |
| 44 | Consumer views are scoped only to current activated certified authority. | SOURCE IMPLEMENTED |
| 45 | Authority advisory lock plus latest-event view prevents simultaneous effective authorities; runtime double-activation test required. | RUNTIME REQUIRED |
| 46 | Replay is required after resume; source-derived canonical outputs are compared. | RUNTIME REQUIRED |
| 47 | Replay checks 100% of exact bound source population. | RUNTIME REQUIRED |
| 48 | Canonical JSON recursively sorts object keys and source traversals use deterministic order. | SOURCE IMPLEMENTED |
| 49 | Replay compares canonical identities/evidence, not random surrogate UUID equality. | SOURCE IMPLEMENTED |
| 50 | Unique lineage disposition per run/source/raw_record; certification reconciles bound count to lineage. | SOURCE IMPLEMENTED |
| 51 | Fatal conflicts persist and block certification/activation. | SOURCE IMPLEMENTED |
| 52 | Conflict rows receive durable CONFLICT lineage and replay verifies conflict evidence. | SOURCE IMPLEMENTED |
| 53 | Evaluation IDs preserve failed certification attempts; finalization inserts new immutable certification run. | SOURCE IMPLEMENTED |
| 54 | Policy bumped to 2.1.2 and exact policy SHA is bound to run/evaluation. | SOURCE IMPLEMENTED |
| 55 | Dependency freeze is mandatory and currently intentionally fail-closed until a connected builder resolves lock metadata. | RUNTIME REQUIRED |
| 56 | Source manifest/SBOM/package hygiene are regenerated for V2.1.2; transient build directories excluded. | SOURCE IMPLEMENTED |
| 57 | Migration runner records ordered migration SHA and supports fresh/V2.1/historical staging matrix. | RUNTIME REQUIRED |
| 58 | Migration history rejects same filename with changed SHA. | SOURCE IMPLEMENTED |
| 59 | Rollback is non-destructive authority rollback; historical evidence is retained. | SOURCE IMPLEMENTED |
| 60 | Upgrade rollback is a mandatory external runtime attestation. | RUNTIME REQUIRED |
| 61 | RBAC revokes direct certification/authority DML and separates reader/normalizer/certifier/runtime tester. | SOURCE IMPLEMENTED |
| 62 | Runtime catalog scan and negative SQL tests enforce foreign-domain DML denial. | RUNTIME REQUIRED |
| 63 | R1B remains proposal/candidate-only; final search authorization is external. | SOURCE IMPLEMENTED |
| 64 | No retailer/store master authority is introduced. | SOURCE IMPLEMENTED |
| 65 | No tax authority objects or calculations are introduced. | SOURCE IMPLEMENTED |
| 66 | No final search authorization or search-budget authority is introduced. | SOURCE IMPLEMENTED |
| 67 | PostGIS certified spatial surfaces retained; ST_MakePoint(longitude,latitude) preserved. | SOURCE IMPLEMENTED |
| 68 | Coordinate parsing validates finite values/ranges; NULL pair consistency certified. | SOURCE IMPLEMENTED |
| 69 | Exact releases/ingest runs/package/policy are bound; vintage coherence remains mandatory. | SOURCE IMPLEMENTED |
| 70 | New normalization does not use latest-by-time dependency discovery. | SOURCE IMPLEMENTED |
| 71 | Run/evaluation/certification bind exact package SHA; old working-tree data cannot be silently re-labeled. | SOURCE IMPLEMENTED |
| 72 | R5 reuse is allowed only with byte/evidence equivalence; otherwise new governed normalization is required. | RUNTIME REQUIRED |
| 73 | VACUUM/ANALYZE/bloat are runtime performance-review requirements. | RUNTIME REQUIRED |
| 74 | WAL/temp/IO/replication/resource effects are mandatory performance evidence. | RUNTIME REQUIRED |
| 75 | Page transactions avoid idle-in-transaction design; pool behavior remains staging-measured. | RUNTIME REQUIRED |
| 76 | Stable query shapes are used; prepared/generic plan behavior remains query-plan review evidence. | RUNTIME REQUIRED |
| 77 | Checkpoint/performance event tables provide run/source/page diagnostics; secrets are not embedded. | SOURCE IMPLEMENTED |
| 78 | Performance/checkpoint/conflict/replay/certification metrics are represented as low-cardinality runtime evidence; deployment exporter remains environment-specific. | SOURCE IMPLEMENTED |
| 79 | Durable resume is the retry model; semantic conflicts are not auto-retried. Transient retry behavior must be exercised externally. | RUNTIME REQUIRED |
| 80 | Checkpoint error_code retains deterministic failure class prefix; runtime runbook distinguishes infra/timeout/deadlock/data/policy defects. | SOURCE IMPLEMENTED |
| 81 | Performance evidence is keyed by source and page. | RUNTIME REQUIRED |
| 82 | Certification independently recalculates checkpoint counts from DB truth. | SOURCE IMPLEMENTED |
| 83 | locations_processed is documented as an operational attempt counter and is not used as authoritative certification truth. | SOURCE IMPLEMENTED |
| 84 | Lineage is authoritative and reconciled directly from DB, avoiding ambiguous app counters. | SOURCE IMPLEMENTED |
| 85 | sha256Json uses stable canonical JSON with recursive key ordering. | SOURCE IMPLEMENTED |
| 86 | Canonical relationship hash binds parent, child, type, authority, ratios and source release; per-record SHA remains separate provenance. | SOURCE IMPLEMENTED |
| 87 | Replay rebuilds from certified raw evidence and policy normalizers, not output hashes alone. | SOURCE IMPLEMENTED |
| 88 | Checks require signed HMAC attestation imported by controlled function; direct runtime-check DML is revoked. | SOURCE IMPLEMENTED |
| 89 | All listed source/runtime/performance/RBAC/activation/rollback/dependency/downstream checks are mandatory finalization names. | RUNTIME REQUIRED |
| 90 | postgres_performance_runtime_pass is mandatory. | RUNTIME REQUIRED |
| 91 | Numeric SLOs are policy/gate inputs. | RUNTIME REQUIRED |
| 92 | V2.1 vs V2.1.2 comparative benchmark is required in staging performance attestation. | RUNTIME REQUIRED |
| 93 | Small-run edge cases remain test/integration requirements; source unit suite includes normalizer edges. | RUNTIME REQUIRED |
| 94 | Multi-parent pair reconciliation detects truncation; production fixture multiplicity remains runtime tested. | RUNTIME REQUIRED |
| 95 | Normalizers fail closed on malformed identifiers/ratios/coordinates; integration fixtures must extend malformed cases. | RUNTIME REQUIRED |
| 96 | Unicode text is NFC-normalized; identity does not depend on mutable display name. | SOURCE IMPLEMENTED |
| 97 | SQL is parameterized; secrets are env/secret-manager inputs and not packaged. | SOURCE IMPLEMENTED |
| 98 | TypeScript strict/noImplicitAny/strictNullChecks/noUncheckedIndexedAccess remain enabled. | SOURCE IMPLEMENTED |
| 99 | PostgreSQL bigint/numeric are treated as strings/exact decimals in authoritative Node paths. | SOURCE IMPLEMENTED |
| 100 | DB trigger enforces allowed normalization state transitions. | SOURCE IMPLEMENTED |
| 101 | Certification and activation are separate controlled DB functions bound to exact run/package/policy/evidence. | SOURCE IMPLEMENTED |
| 102 | Controlled revocation writes immutable authority event and preserves history. | SOURCE IMPLEMENTED |
| 103 | External view contract is frozen in config/downstream-contract.json and runtime-verified. | RUNTIME REQUIRED |
| 104 | Engine compatibility and exact package SHA are distinct provenance fields. | SOURCE IMPLEMENTED |
| 105 | Ownership collision matrix is included and runtime grants are checked. | SOURCE IMPLEMENTED |
| 106 | Adversarial scenarios are formalized in runtime runbook/integration attestation requirement. | RUNTIME REQUIRED |
| 107 | Real PostgreSQL/PostGIS integration evidence is mandatory; mocks cannot satisfy finalization. | RUNTIME REQUIRED |
| 108 | PostGIS/pgcrypto presence is checked in runtime certification. | RUNTIME REQUIRED |
| 109 | Fresh install is part of integration attestation. | RUNTIME REQUIRED |
| 110 | V2.1 upgrade install is part of integration attestation. | RUNTIME REQUIRED |
| 111 | Partial migration failure/recovery is part of integration/rollback proof. | RUNTIME REQUIRED |
| 112 | Clean connected npm ci/typecheck/build/test/manifest validation is required. | RUNTIME REQUIRED |
| 113 | Final package SHA is generated outside the ZIP and reported. | SOURCE IMPLEMENTED |
| 114 | Generated evidence is regenerated/verified; templates are explicitly non-evidence. | SOURCE IMPLEMENTED |
| 115 | Severity doctrine retained in final hardening report. | SOURCE IMPLEMENTED |
| 116 | P0/P1 reporting schema retained in remediation/report documentation. | SOURCE IMPLEMENTED |
| 117 | No automatic full rerun: remediation must classify whether authority data is affected. | SOURCE IMPLEMENTED |
| 118 | Functionality-preservation matrix is included in hardening report. | SOURCE IMPLEMENTED |
| 119 | SQL performance evidence table is required from staging attestation. | RUNTIME REQUIRED |
| 120 | Data-correctness gate table is included in final report/runtime evidence. | RUNTIME REQUIRED |
| 121 | Ownership gate table is included and tied to actual grants/code paths. | SOURCE IMPLEMENTED |
| 122 | Executive gate is emitted in final hardening report. | RUNTIME REQUIRED |
| 123 | All listed blockers are implemented as mandatory gates or explicit fail-closed release conditions. | RUNTIME REQUIRED |
| 124 | All named implementation files plus migration 010 are included in source manifest/review scope. | SOURCE IMPLEMENTED |
| 125 | The listed hidden-defect patterns were directly hardened or converted to runtime-required evidence. | SOURCE IMPLEMENTED |
| 126 | Final reviewer conclusion requirements are included in final hardening report. | SOURCE IMPLEMENTED |
| 127 | Final-freeze doctrine explicitly requires exact sealed artifact + production-scale PostgreSQL/PostGIS evidence with zero unresolved P0/P1. | RUNTIME REQUIRED |
