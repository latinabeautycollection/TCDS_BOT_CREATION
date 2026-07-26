# Milestone 1B.6 — Backup and Rollback Engine v1.0.0

Provides governed, component-allowlisted backup sets; streamed content-addressed
blobs; recursive directory capture; metadata and xattr preservation; quotas;
verified manifests; restore planning; approval challenges; isolated restore
rehearsal; rollback eligibility; retention; local immutable-export staging; and
a transactional SQLite WAL catalog with hash-linked events.

Envoy, Suricata, and PQP backup roots are explicitly registered. The engine
rejects symlinks, special files, filesystem crossings, and paths outside the
component contract. Production use of secret/private-key backups requires an
approved encryption hook. Authoritative evidence requires a separate immutable
remote destination; this package does not invent credentials or cloud storage.
