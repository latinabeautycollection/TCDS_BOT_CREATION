BEGIN;

-- Non-destructive rollback. Preserve all qualification and certification evidence.
UPDATE retail.r1e_match_rulesets
SET certification_status='suspended'
WHERE certification_status='certified';

COMMIT;
