# Migration Dependency Matrix

| Migration | Requires | Creates / modifies | Rollback model | Static result |
|---|---|---|---|---|
| 042a | existing ZSL1 + `zsl_raw.raw_records` | tax acquisition core | evidence-preserving | PASS |
| 042b | 042a | RBAC | revoke/grant reversal | PASS |
| 042c | 042a/b | strict ingest/certification | function replacement | PASS |
| 042d | 042a-c | national publication | append-only publication | PASS |
| 043 | ZSL5 V1.2 + 042 | V1.4 compatibility/runtime tables | additive | PASS |
| 043a | 043 | 21 family views | replace views | PASS |
| 043b | 043/042d | binding validity | replace function/view | PASS |
| 043c | 043b | activation | replaced by later hardened definition | PASS |
| 044a/b | 042/043 | runtime population/state gates | append-only | PASS |
| 045/045a | 043/044 | ZSL5 load/runtime certification | append-only | PASS |
| 046a-c | 045 | adversarial/freshness/category gates | additive | PASS |
| **047a** | 043-046 | DB/type/temporal/payload hardening | additive constraints/views | PASS static |
| **047b** | active-authority surfaces | ZSL5→ZSL6 read-only view | drop/replace view | PASS static |
| **047c** | 046 + 047a/b | final-freeze activation gate | replace function/view | PASS static |

A clean-clone staging migration run is still required before production certification.
