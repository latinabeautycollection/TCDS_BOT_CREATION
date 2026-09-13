BEGIN;

-- Non-destructive R1C V3 rollback: preserve compiler, binding and job evidence.
UPDATE retail.search_compiler_versions
SET certification_status='suspended'
WHERE certification_status='certified';

UPDATE retail.search_job_compilations
SET compilation_status='invalidated'
WHERE compilation_status='compiled';

UPDATE retail.search_route_compile_profiles
SET profile_status='suspended'
WHERE profile_status='active';

UPDATE retail.r1c_v3_state
SET doctrine=doctrine||' [PRODUCTION_ROLLBACK_SUSPENDED]'
WHERE singleton=true;

COMMIT;
