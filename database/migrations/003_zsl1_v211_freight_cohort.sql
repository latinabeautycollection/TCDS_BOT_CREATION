BEGIN;

-- Additive source registration only. Existing certified releases and policies are untouched.
INSERT INTO zsl.source_registry(source_key,source_name,source_class,authority_level,access_type,landing_url)
VALUES
  ('BTS_FAF6_ZONE_LOOKUP','BTS Freight Analysis Framework 6 - Zone Lookup','LOGISTICS_FREIGHT','FEDERAL','BULK_FILE','https://www.bts.gov/faf'),
  ('BTS_SCTG_METADATA','BTS Standard Classification of Transported Goods Metadata','LOGISTICS_FREIGHT','FEDERAL','BULK_FILE','https://www.bts.gov/faf'),
  ('CENSUS_CBP','U.S. Census County Business Patterns','LOGISTICS_FREIGHT','FEDERAL','BULK_FILE','https://www.census.gov/programs-surveys/cbp.html')
ON CONFLICT(source_key) DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zsl_ingest_worker') THEN
    GRANT SELECT,INSERT ON zsl.source_registry,zsl.source_releases,zsl.ingest_runs,zsl.source_artifacts,
      zsl.release_record_memberships,zsl.ingest_attempts,zsl.schema_validation_runs TO zsl_ingest_worker;
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'Freight cohort grants skipped: apply using the database owner.';
END $$;

COMMIT;
