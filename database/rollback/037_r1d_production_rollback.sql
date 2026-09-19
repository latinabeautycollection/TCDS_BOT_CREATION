BEGIN;

-- Non-destructive production rollback.
-- Stop future dispatch, preserve all jobs, attempts, budgets, bindings and evidence.

UPDATE retail.r1d_dispatch_bindings
SET certification_status='suspended',updated_at=now()
WHERE certification_status='certified';

UPDATE retail.r1d_dispatch_jobs
SET status='cancelled',
    last_error_code='R1D_PRODUCTION_ROLLBACK',
    last_error_message='R1D production rollback cancelled undispatched job',
    updated_at=now()
WHERE status IN('queued','retry_wait');

-- Active leased/dispatching jobs are intentionally not force-cancelled here.
-- They must complete or be reconciled by the lease reaper so budget truth
-- remains conservative.

UPDATE retail.r1d_compilation_schedule_state
SET activation_state='suppressed',
    activation_source='system',
    activation_reason='R1D production rollback',
    updated_at=now()
WHERE activation_state IN('baseline','activated');

COMMIT;
