# Milestone 1B.5 — State and Transaction Engine

Adds authoritative lifecycle state, optimistic concurrency, idempotent transaction
creation, hash-chained transaction journaling, verified file checkpoints,
controlled restore, and crash reconciliation.

Interrupted APPLYING, VALIDATING, COMMITTING, or ROLLING_BACK transactions are
marked RECOVERY_REQUIRED. The framework never automatically repeats uncertain
operations. This protects Envoy, Suricata, PQP, and other control-plane changes
from silent duplication after a crash.
