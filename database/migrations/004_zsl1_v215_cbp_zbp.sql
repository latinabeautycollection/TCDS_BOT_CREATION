BEGIN;

-- Additive registration only. Existing releases, certifications, and authorities remain unchanged.
INSERT INTO zsl.source_registry(source_key,source_name,source_class,authority_level,access_type,landing_url)
VALUES ('CENSUS_ZBP','U.S. Census ZIP Code Business Patterns','LOGISTICS_FREIGHT','FEDERAL','BULK_FILE','https://www.census.gov/programs-surveys/cbp.html')
ON CONFLICT(source_key) DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zsl_ingest_worker') THEN
    GRANT SELECT,INSERT ON zsl.source_registry,zsl.source_releases,zsl.ingest_runs,zsl.source_artifacts,
      zsl.release_record_memberships,zsl.ingest_attempts,zsl.schema_validation_runs TO zsl_ingest_worker;
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'CBP/ZBP successor grants skipped: apply using the database owner.';
END $$;

COMMIT;
