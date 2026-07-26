# Milestone 1B.7 — Validation and Health Framework v1.2.0

This milestone supplies the validation receipts and health gates consumed by
the 1B.5 transaction engine and the 1B.6 backup/restore engine.

It defines side-effect-free contracts for Envoy, Suricata, PQP, PostgreSQL,
Redis, telemetry, and clock synchronization. Contracts are declarative and do
not restart, reload, signal, or reconfigure services.

The initial package includes executable contracts only where the validation can
be safely expressed without server-specific secrets or inventory. Missing
required component contracts fail closed in production. Server-specific checks
such as listener/cluster/route comparison, Suricata packet-drop thresholds, and
PQP correlation queries are registered during the component configuration
milestone after actual paths, ports, schemas, and credentials are known.
