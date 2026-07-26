# EIF Source Snapshot

Framework version: 1.5.0
Deployment root: /opt/tcds/TCDS_Enterprise_Infrastructure
Deployment owner: ingest:ingest

This directory contains immutable source, configuration, schemas, tests,
release evidence, and controlled recovery installers for EIF milestones
1B.2 through 1B.8.

The stock milestone installers are retained as upstream release evidence.
Production deployment must use the reviewed scripts in tools/recovery in
milestone order.

The source snapshot deliberately excludes mutable deployment data:

- backups and backup databases
- runtime-resolved configuration
- state databases and locks
- logs and events
- health and certification output
- deployment-specific installation manifests
- generated Python caches
- temporary files

Milestone 1B.8 passed staged and live UNIT_TEST certification. Full
production certification remains pending live infrastructure acceptance
evidence for Envoy, Suricata, PQP, PostgreSQL, Redis, remote immutable
evidence, and dedicated service-account controls.
