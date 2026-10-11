# ZSL2 V2.1.2 PostgreSQL/PostGIS Runtime Certification Runbook

This package intentionally does not self-award runtime or performance certification from static/source tests.

## 1. Build and dependency freeze

On a connected clean Node 22 builder run `npm ci`, regenerate a complete npm lockfile, and execute `node scripts/verify-lock.mjs`. Final Freeze is blocked until every lock entry that requires registry provenance contains `resolved` and `integrity` metadata and the lockfile is sealed.

## 2. Install / upgrade test matrix

Run `scripts/migrate.sh` against: (a) fresh PostgreSQL/PostGIS; (b) a clone of V2.1; (c) a clone containing historical R5 data. The migration ledger must reject changed migration SHAs.

## 3. Privileged attestation key registration

A DB owner retrieves the HMAC secret from the organization's secret manager and executes `database/runtime/000_register_attestation_key.sql`. The secret must never be embedded in the ZIP or granted to ZSL2 database roles.

## 4. PostgreSQL integration suite

Execute migrations, six-source fixtures, normalization, crash/resume boundaries, conflict cases, ratio reconciliation, deterministic replay, certification prepare/finalize, activation, revocation and non-destructive rollback using real PostgreSQL + PostGIS. Generate an immutable integration attestation modeled on `evidence/templates/postgres-integration.example.json`.

Required failure injections include connection loss and process termination before/after page writes and checkpoint updates. Same-run concurrent workers must serialize on `zsl2_lock_source_page`.

## 5. Production-scale performance

Use at least the known workload scale (~171,633 source records / ~90,984 relationships, including full HUD ZIP-CBSA). Run `EXPLAIN (ANALYZE, BUFFERS, WAL, VERBOSE, SETTINGS)` for the major source-page, relationship, lineage, checkpoint, ratio, replay and authority queries. Compare candidate page sizes 250/500/1000/2000/5000 where applicable.

Mandatory package thresholds are P99 normal page duration < 60,000 ms and maximum normal page duration < 120,000 ms. No global `statement_timeout` increase is an acceptable substitute for query design.

Generate `performance.json` modeled on the provided template and retain query-plan SHA evidence.

## 6. RBAC and collision tests

Run `database/runtime/002_rbac_negative_tests.sql` and actual `SET ROLE` tests. ZSL2 roles must receive `permission denied` for foreign-domain DML. A reader cannot mutate canonical data; normalizer cannot certify/activate; certifier cannot rewrite normalization evidence by direct DML.

## 7. Activation probe

Use a disposable certified fixture. Supply `ZSL2_RUNTIME_FIXTURE_RUN_ID` and `ZSL2_RUNTIME_FIXTURE_CERT_ID`; runtime certification executes controlled activation inside a savepoint and rolls it back. Without a safe fixture this gate intentionally fails closed.

## 8. Rollback proof

Prove non-destructive authority rollback on a staging clone. Historical lineage, failed certifications and normalized evidence must remain. Generate the signed rollback attestation.

## 9. Runtime certification and finalization

Run `npm run certify:prepare -- <run>`, then `npm run runtime:certify -- <run> <evaluation>`, then `npm run certify:finalize -- <run> <evaluation>`. The DB finalizer calculates CERTIFIED only when every mandatory control exists and is PASS.

## 10. Production activation

Activation is a separate explicit action and uses `zsl2_activate`. Do not activate unless the exact package SHA, policy SHA, source bindings and source snapshots still match.
