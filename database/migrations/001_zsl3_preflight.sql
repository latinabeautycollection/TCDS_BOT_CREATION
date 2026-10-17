BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
DO $$
BEGIN
  IF to_regclass('zsl.source_registry') IS NULL OR to_regclass('zsl.certification_runs') IS NULL THEN
    RAISE EXCEPTION 'ZSL3_REQUIRES_ZSL1';
  END IF;
  IF to_regclass('zsl.zsl2_current_authority') IS NULL OR to_regclass('zsl.certified_canonical_locations') IS NULL THEN
    RAISE EXCEPTION 'ZSL3_REQUIRES_ZSL2_V21';
  END IF;
END $$;
COMMIT;
