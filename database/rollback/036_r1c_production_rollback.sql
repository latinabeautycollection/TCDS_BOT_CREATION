BEGIN;
-- Non-destructive production rollback. Preserve all compiler/job/certification evidence.
UPDATE retail.search_compiler_versions
SET certification_status='suspended'
WHERE certification_status='certified';

UPDATE retail.search_job_compilations
SET compilation_status='invalidated'
WHERE compilation_status='compiled';

UPDATE retail.search_route_compile_profiles
SET profile_status='suspended'
WHERE profile_status='active';

UPDATE retail.r1c_schema_state
SET ownership_doctrine=ownership_doctrine||' [PRODUCTION_ROLLBACK_SUSPENDED]'
WHERE singleton=true;
COMMIT;
