BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;
CREATE SCHEMA IF NOT EXISTS zsl;

DO $$
BEGIN
  IF to_regclass('zsl.certified_release_records') IS NULL THEN
    RAISE EXCEPTION 'ZSL2_REQUIRES_ZSL1_CERTIFIED_RELEASE_RECORDS';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='postgis') THEN
    RAISE EXCEPTION 'ZSL2_REQUIRES_POSTGIS';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS zsl.zsl2_schema_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  schema_version text NOT NULL,
  engine_version text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  package_sha256 text CHECK(package_sha256 IS NULL OR package_sha256 ~ '^[0-9a-f]{64}$'),
  git_sha text,
  CHECK(schema_version='2.1.0'),
  CHECK(engine_version='zsl2-v2.1.0')
);
INSERT INTO zsl.zsl2_schema_state(singleton,schema_version,engine_version)
VALUES(true,'2.1.0','zsl2-v2.1.0')
ON CONFLICT(singleton) DO UPDATE SET schema_version=EXCLUDED.schema_version,engine_version=EXCLUDED.engine_version;

CREATE OR REPLACE FUNCTION zsl.zsl2_sha256_jsonb(p_doc jsonb)
RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
 SELECT encode(digest(convert_to(p_doc::text,'UTF8'),'sha256'),'hex')
$$;
COMMIT;
