# Milestone 1B.5 Green Tier 1 v0.9.0

Transactional SQLite WAL state store; request-bound idempotency; gate enforcement; component checkpoint allowlists; recursive streamed checkpoints with quotas; leases and heartbeat reconciliation; hash-linked transactional event records; Envoy, Suricata, and PQP commit gates; saga records; verified release installation and automatic rollback.

For authoritative production, configure the PostgreSQL audit mirror, HMAC key, checkpoint encryption hook, and remote immutable evidence export. These external credentials are deliberately not embedded.
