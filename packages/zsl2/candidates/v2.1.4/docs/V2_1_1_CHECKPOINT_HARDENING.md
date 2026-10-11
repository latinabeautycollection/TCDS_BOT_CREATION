# ZSL2 V2.1.1 Checkpoint & Performance Hardening

This patch keeps the downstream runtime engine contract at `zsl2-v2.1.0` while correcting the normalization execution model and HUD ratio certification semantics.

## Root causes addressed

1. Long-running all-or-nothing normalization was vulnerable to statement timeout and rollback late in the six-source sequence.
2. OFFSET pagination made later pages progressively more expensive.
3. HUD relationship loading performed excessive per-row database work.
4. Certification incorrectly required RES/BUS/OTH aggregate ratios to total 1 even when a component population is legitimately absent.
5. Runtime checks were unique only by normalization run, preventing clean immutable re-evaluation attempts.

## V2.1.1 changes

- Durable source/page checkpoints.
- Resume by existing normalization run UUID.
- Keyset pagination on `(ordinal, record_id)`.
- Page-sized transactions; partial work remains excluded from certified authority views.
- HUD relationship staging with set-based relationship, membership, and lineage inserts.
- Source-specific page sizing (HUD ZIP-CBSA defaults to 1000; HUD ZIP-County to 2000).
- Recoverable page failures return the overall run to `STARTED` instead of destroying completed work.
- Certification requires exactly six COMPLETE checkpoints.
- HUD RES/BUS/OTH grouped totals must be approximately 0 or 1; TOT must be approximately 1.
- Zero-component groups are recorded in certification evidence.
- Certification checks are scoped to immutable evaluation IDs so failed attempts remain auditable.

## Runtime certification still required

Source-level validation cannot prove PostgreSQL execution time, lock behavior, query plans, Supabase statement timeout behavior, or production RBAC. Final freeze still requires a real staging run against the target PostgreSQL/Supabase environment.
