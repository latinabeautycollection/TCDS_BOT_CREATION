BEGIN;

-- Non-destructive rollback: preserve all R1F facts, snapshots,
-- recommendations and certification evidence.

UPDATE retail.r1f_intelligence_policies
SET certification_status='suspended'
WHERE certification_status='certified';

UPDATE retail.r1f_certification_policies
SET certification_status='suspended'
WHERE certification_status='certified';

UPDATE retail.r1f_search_recommendations
SET status='EXPIRED',
    decision_by='R1F_PRODUCTION_ROLLBACK',
    decision_at=now(),
    decision_reason='R1F production rollback'
WHERE status='PROPOSED';

COMMIT;
