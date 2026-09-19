BEGIN;

-- Non-destructive R1E V2.1 rollback. Preserve all result/certification evidence.
UPDATE retail.r1e_match_rulesets
SET certification_status='suspended'
WHERE certification_status='certified';

UPDATE retail.r1e_certification_policies
SET certification_status='suspended'
WHERE certification_status='certified';

COMMIT;
