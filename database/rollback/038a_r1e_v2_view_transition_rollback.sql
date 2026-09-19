BEGIN;

-- Transitional migration has no independent production rollback.
-- R1E production rollback suspends certified authority without restoring V1 views.

COMMIT;
