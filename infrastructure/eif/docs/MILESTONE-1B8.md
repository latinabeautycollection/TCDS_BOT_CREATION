# Milestone 1B.8 — Framework Test Harness and Certification Suite v1.4.0

This milestone closes the 1B framework by orchestrating regression, security,
concurrency, failure-injection, recovery, integration, and production acceptance
tests into one HMAC-authenticated certification report.

A framework may receive `GREEN_TIER_1` only when all selected suites pass and
all host-level production acceptance prerequisites are present. Passing code
tests without the real Envoy, Suricata, PQP, PostgreSQL, Redis, immutable
evidence export, service accounts, and security confinement produces `AMBER`,
not a false production certification.

The suite is side-effect-free by default. It does not restart or reload Envoy,
Suricata, PQP, Redis, PostgreSQL, NGINX, Grafana, Loki, or Alertmanager.
