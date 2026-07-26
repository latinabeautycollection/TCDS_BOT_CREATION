# Production acceptance requirements

Final Green Tier 1 certification requires:

- Envoy installed, trusted, loopback admin isolated, configuration validated.
- Suricata installed, trusted, rules validated, EVE and JA3/JA4 evidence healthy.
- PQP `/health` and `/ready` passing.
- PostgreSQL and Redis validation credentials configured.
- Telemetry queue, dead-letter, and export-lag probes connected.
- HMAC keys delivered from approved secret providers.
- Remote immutable evidence destination verified.
- Dedicated `tcds-validator` service account.
- AppArmor, SELinux, or an approved equivalent confinement control.
- Complete 1B.1–1B.7 regression suite.
- No critical or high-severity findings.
