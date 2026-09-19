BEGIN;

-- Non-destructive V2 production rollback.
UPDATE retail.r1d_dispatch_bindings
SET certification_status='suspended',updated_at=now()
WHERE certification_status='certified';

-- Release work that has not crossed dispatch boundary.
WITH q AS (
  SELECT id FROM retail.r1d_dispatch_jobs
  WHERE status IN('queued','retry_wait','leased')
  FOR UPDATE
)
UPDATE retail.r1d_dispatch_jobs j
SET status='cancelled',
    lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
    circuit_permit_token=NULL,
    last_error_code='R1D_V2_ROLLBACK',
    last_error_message='R1D V2 production rollback',
    updated_at=now()
FROM q WHERE j.id=q.id;

UPDATE retail.r1d_budget_reservations r
SET status='released',settled_at=now()
WHERE status='reserved'
  AND EXISTS(
    SELECT 1 FROM retail.r1d_dispatch_jobs j
    WHERE j.id=r.job_id AND j.status='cancelled'
  );

UPDATE retail.r1d_rate_reservations r
SET status='released',released_at=now()
WHERE status='reserved'
  AND EXISTS(
    SELECT 1 FROM retail.r1d_dispatch_jobs j
    WHERE j.id=r.job_id AND j.status='cancelled'
  );

-- Dispatching work is left for conservative lease reconciliation.
UPDATE retail.r1d_compilation_schedule_state
SET activation_state='suppressed',
    activation_source='system',
    activation_reason='R1D V2 production rollback',
    updated_at=now()
WHERE activation_state IN('baseline','activated');

COMMIT;
