BEGIN;

-- Non-destructive R1F V2 rollback.
-- Preserve all V2 facts, observations, snapshots, recommendations and certification evidence.

UPDATE retail.r1f_intelligence_policies
SET certification_status='suspended'
WHERE certification_status='certified';

UPDATE retail.r1f_certification_policies
SET certification_status='suspended'
WHERE certification_status='certified';

UPDATE retail.r1f_search_recommendations
SET status='EXPIRED',
    decision_by='R1F_V2_PRODUCTION_ROLLBACK',
    decision_at=now(),
    decision_reason='R1F V2 production rollback'
WHERE status='PROPOSED'
  AND engine_version='r1f-v2.0.0';

COMMIT;
