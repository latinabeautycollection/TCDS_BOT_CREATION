# Milestone 1B.7 Green Tier 1 v1.3.0

This one-time hardening release enforces validation phases, mandatory check sets,
component ownership, trusted execution through 1B.4, transaction linkage through
1B.5, authoritative evidence queries, HMAC receipts, audit linkage, atomic
receipt persistence, health staleness, maintenance state, Prometheus metrics,
Alertmanager rules, and least-privilege systemd templates.

Server-specific composite probes fail closed until their approved probe producer
is configured. This prevents fabricated PASS results before Envoy, Suricata, and
PQP inventory and evidence queries are connected to the actual server.
