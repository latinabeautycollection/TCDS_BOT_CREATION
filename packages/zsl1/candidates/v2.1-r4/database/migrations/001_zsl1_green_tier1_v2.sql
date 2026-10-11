BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS zsl;
CREATE SCHEMA IF NOT EXISTS zsl_raw;

REVOKE ALL ON SCHEMA zsl_raw FROM PUBLIC;
REVOKE ALL ON SCHEMA zsl FROM PUBLIC;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zsl_ingest_worker') THEN
    CREATE ROLE zsl_ingest_worker NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zsl_normalizer') THEN
    CREATE ROLE zsl_normalizer NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zsl_reader') THEN
    CREATE ROLE zsl_reader NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zsl_certifier') THEN
    CREATE ROLE zsl_certifier NOLOGIN;
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'Role creation skipped: insufficient privilege; provision roles externally and re-run grants.';
END $$;

CREATE TABLE IF NOT EXISTS zsl.source_registry(
  source_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_key text NOT NULL UNIQUE CHECK (btrim(source_key) <> ''),
  source_name text NOT NULL CHECK (btrim(source_name) <> ''),
  source_class text NOT NULL CHECK (btrim(source_class) <> ''),
  authority_level text NOT NULL,
  access_type text NOT NULL,
  landing_url text,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS zsl.source_releases(
  release_id uuid PRIMARY KEY,
  source_id uuid NOT NULL REFERENCES zsl.source_registry(source_id),
  release_key text NOT NULL CHECK (btrim(release_key) <> ''),
  release_label text NOT NULL,
  source_year int CHECK (source_year IS NULL OR source_year BETWEEN 1900 AND 2200),
  source_quarter int CHECK (source_quarter IS NULL OR source_quarter BETWEEN 1 AND 4),
  discovered_at timestamptz NOT NULL,
  status text NOT NULL CHECK(status IN ('DISCOVERED','DOWNLOADED','VALIDATED','LOADED','RECONCILED','SUPERSEDED','QUARANTINED')),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(source_id,release_key)
);

CREATE TABLE IF NOT EXISTS zsl.source_release_discoveries(
  discovery_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES zsl.source_registry(source_id),
  release_key text NOT NULL,
  discovered_at timestamptz NOT NULL DEFAULT now(),
  discovery_document jsonb NOT NULL CHECK(jsonb_typeof(discovery_document)='object'),
  discovery_sha256 text NOT NULL CHECK(discovery_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE TABLE IF NOT EXISTS zsl.ingest_runs(
  ingest_run_id uuid PRIMARY KEY,
  release_id uuid NOT NULL REFERENCES zsl.source_releases(release_id),
  state text NOT NULL CHECK(state IN ('DISCOVERED','DOWNLOADED','VALIDATED','LOADED','RECONCILED','FAILED','QUARANTINED','SUPERSEDED')),
  policy_sha256 text NOT NULL CHECK(policy_sha256 ~ '^[0-9a-f]{64}$'),
  adapter_version text NOT NULL,
  application_version text NOT NULL,
  git_sha text,
  package_sha256 text CHECK(package_sha256 IS NULL OR package_sha256 ~ '^[0-9a-f]{64}$'),
  actor text NOT NULL,
  host_id text,
  parsed_record_count bigint NOT NULL DEFAULT 0 CHECK(parsed_record_count>=0),
  loaded_membership_count bigint NOT NULL DEFAULT 0 CHECK(loaded_membership_count>=0),
  distinct_record_count bigint NOT NULL DEFAULT 0 CHECK(distinct_record_count>=0),
  failure_code text,
  failure_detail text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  CHECK(finished_at IS NULL OR finished_at>=started_at)
);

CREATE INDEX IF NOT EXISTS ix_ingest_runs_release_time ON zsl.ingest_runs(release_id,started_at DESC);

CREATE TABLE IF NOT EXISTS zsl.ingest_attempts(
  ingest_attempt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ingest_run_id uuid NOT NULL REFERENCES zsl.ingest_runs(ingest_run_id),
  attempt_no int NOT NULL CHECK(attempt_no>0),
  stage text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  success boolean,
  error_code text,
  error_detail text,
  UNIQUE(ingest_run_id,attempt_no,stage)
);

CREATE TABLE IF NOT EXISTS zsl.source_artifacts(
  artifact_id uuid PRIMARY KEY,
  release_id uuid NOT NULL REFERENCES zsl.source_releases(release_id),
  retrieval_ingest_run_id uuid NOT NULL REFERENCES zsl.ingest_runs(ingest_run_id),
  source_url text NOT NULL,
  original_filename text NOT NULL,
  content_type text,
  byte_count bigint NOT NULL CHECK(byte_count>0),
  sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
  etag text,
  last_modified text,
  object_storage_uri text NOT NULL,
  retrieved_at timestamptz NOT NULL,
  UNIQUE(release_id,sha256)
);

CREATE TABLE IF NOT EXISTS zsl_raw.raw_records(
  record_id uuid PRIMARY KEY,
  record_sha256 text NOT NULL UNIQUE CHECK(record_sha256 ~ '^[0-9a-f]{64}$'),
  natural_key text NOT NULL,
  record jsonb NOT NULL CHECK(jsonb_typeof(record)='object'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_raw_records_natural_key ON zsl_raw.raw_records(natural_key);
CREATE INDEX IF NOT EXISTS ix_raw_records_gin ON zsl_raw.raw_records USING gin(record);

CREATE TABLE IF NOT EXISTS zsl.release_record_memberships(
  release_id uuid NOT NULL REFERENCES zsl.source_releases(release_id),
  artifact_id uuid NOT NULL REFERENCES zsl.source_artifacts(artifact_id),
  record_id uuid NOT NULL REFERENCES zsl_raw.raw_records(record_id),
  ordinal bigint NOT NULL CHECK(ordinal>0),
  PRIMARY KEY(release_id,artifact_id,ordinal),
  UNIQUE(release_id,artifact_id,record_id)
);

CREATE TABLE IF NOT EXISTS zsl.schema_contracts(
  schema_contract_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES zsl.source_registry(source_id),
  contract_version text NOT NULL,
  contract_document jsonb NOT NULL CHECK(jsonb_typeof(contract_document)='object'),
  contract_sha256 text NOT NULL CHECK(contract_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(source_id,contract_version)
);

CREATE TABLE IF NOT EXISTS zsl.schema_validation_runs(
  schema_validation_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ingest_run_id uuid NOT NULL REFERENCES zsl.ingest_runs(ingest_run_id),
  artifact_id uuid NOT NULL REFERENCES zsl.source_artifacts(artifact_id),
  schema_contract_id uuid REFERENCES zsl.schema_contracts(schema_contract_id),
  status text NOT NULL CHECK(status IN ('PASS','FAIL')),
  validation_document jsonb NOT NULL CHECK(jsonb_typeof(validation_document)='object'),
  validation_sha256 text NOT NULL CHECK(validation_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS zsl.source_policies(
  source_policy_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES zsl.source_registry(source_id),
  policy_version text NOT NULL,
  policy_document jsonb NOT NULL CHECK(jsonb_typeof(policy_document)='object'),
  policy_sha256 text NOT NULL CHECK(policy_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(source_id,policy_version)
);

CREATE TABLE IF NOT EXISTS zsl.ingest_audit_events(
  audit_event_id bigserial PRIMARY KEY,
  event_type text NOT NULL,
  actor text NOT NULL,
  event_data jsonb NOT NULL CHECK(jsonb_typeof(event_data)='object'),
  event_sha256 text NOT NULL CHECK(event_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS zsl.certification_policies(
  certification_policy_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_version text NOT NULL UNIQUE,
  policy_document jsonb NOT NULL CHECK(jsonb_typeof(policy_document)='object'),
  policy_sha256 text NOT NULL CHECK(policy_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS zsl.certification_runs(
  certification_run_id uuid PRIMARY KEY,
  ingest_run_id uuid NOT NULL REFERENCES zsl.ingest_runs(ingest_run_id),
  status text NOT NULL CHECK(status IN ('PENDING','CERTIFIED','FAILED','REVOKED','SUPERSEDED')),
  evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'),
  evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
  certifier_actor text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  certified_at timestamptz
);

CREATE INDEX IF NOT EXISTS ix_cert_runs_ingest_time ON zsl.certification_runs(ingest_run_id,created_at DESC);

CREATE OR REPLACE FUNCTION zsl.transition_ingest_state(p_run uuid,p_next text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=zsl,pg_temp
AS $$
DECLARE
  cur text;
  ok boolean:=false;
BEGIN
  SELECT state INTO cur FROM zsl.ingest_runs WHERE ingest_run_id=p_run FOR UPDATE;
  IF cur IS NULL THEN RAISE EXCEPTION 'INGEST_RUN_NOT_FOUND'; END IF;

  ok := CASE
    WHEN cur='DISCOVERED' AND p_next IN ('DOWNLOADED','FAILED','QUARANTINED') THEN true
    WHEN cur='DOWNLOADED' AND p_next IN ('VALIDATED','FAILED','QUARANTINED') THEN true
    WHEN cur='VALIDATED' AND p_next IN ('LOADED','FAILED','QUARANTINED') THEN true
    WHEN cur='LOADED' AND p_next IN ('RECONCILED','FAILED','QUARANTINED') THEN true
    WHEN cur='RECONCILED' AND p_next IN ('SUPERSEDED') THEN true
    ELSE false
  END;
  IF NOT ok THEN RAISE EXCEPTION 'INVALID_INGEST_STATE_TRANSITION:%->%',cur,p_next; END IF;

  UPDATE zsl.ingest_runs
  SET state=p_next,
      finished_at=CASE WHEN p_next IN ('RECONCILED','FAILED','QUARANTINED','SUPERSEDED') THEN now() ELSE finished_at END
  WHERE ingest_run_id=p_run;
END $$;

CREATE OR REPLACE FUNCTION zsl.append_audit_event(p_type text,p_actor text,p_data jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=zsl,pg_temp
AS $$
DECLARE
  id bigint;
  sha text;
BEGIN
  IF btrim(p_type)='' OR btrim(p_actor)='' OR jsonb_typeof(p_data)<>'object' THEN
    RAISE EXCEPTION 'INVALID_AUDIT_EVENT';
  END IF;
  sha := encode(digest(convert_to(jsonb_build_object(
      'event_type',p_type,'actor',p_actor,'event_data',p_data
    )::text,'UTF8'),'sha256'),'hex');
  INSERT INTO zsl.ingest_audit_events(event_type,actor,event_data,event_sha256)
  VALUES(p_type,p_actor,p_data,sha) RETURNING audit_event_id INTO id;
  RETURN id;
END $$;

CREATE OR REPLACE FUNCTION zsl.prevent_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'IMMUTABLE_LEDGER_OBJECT';
END $$;

DROP TRIGGER IF EXISTS trg_raw_records_immutable ON zsl_raw.raw_records;
CREATE TRIGGER trg_raw_records_immutable
BEFORE UPDATE OR DELETE ON zsl_raw.raw_records
FOR EACH ROW EXECUTE FUNCTION zsl.prevent_mutation();

DROP TRIGGER IF EXISTS trg_memberships_immutable ON zsl.release_record_memberships;
CREATE TRIGGER trg_memberships_immutable
BEFORE UPDATE OR DELETE ON zsl.release_record_memberships
FOR EACH ROW EXECUTE FUNCTION zsl.prevent_mutation();

DROP TRIGGER IF EXISTS trg_artifacts_immutable ON zsl.source_artifacts;
CREATE TRIGGER trg_artifacts_immutable
BEFORE UPDATE OR DELETE ON zsl.source_artifacts
FOR EACH ROW EXECUTE FUNCTION zsl.prevent_mutation();

CREATE OR REPLACE VIEW zsl.certified_release_records AS
SELECT
  s.source_key,
  sr.release_id,
  sr.release_key,
  a.artifact_id,
  rr.record_id,
  rr.natural_key,
  rr.record,
  rr.record_sha256
FROM zsl.source_registry s
JOIN zsl.source_releases sr ON sr.source_id=s.source_id
JOIN zsl.ingest_runs ir ON ir.release_id=sr.release_id AND ir.state='RECONCILED'
JOIN LATERAL (
  SELECT cr.*
  FROM zsl.certification_runs cr
  WHERE cr.ingest_run_id=ir.ingest_run_id
  ORDER BY cr.created_at DESC
  LIMIT 1
) cr ON cr.status='CERTIFIED'
JOIN zsl.source_artifacts a ON a.retrieval_ingest_run_id=ir.ingest_run_id
JOIN zsl.release_record_memberships m ON m.release_id=sr.release_id AND m.artifact_id=a.artifact_id
JOIN zsl_raw.raw_records rr ON rr.record_id=m.record_id;

INSERT INTO zsl.source_registry(source_key,source_name,source_class,authority_level,access_type,landing_url)
VALUES
('CENSUS_GAZETTEER_STATE','U.S. Census Gazetteer - States','GEOGRAPHY','FEDERAL','BULK_FILE','https://www.census.gov/geographies/reference-files/time-series/geo/gazetteer-files.html'),
('CENSUS_GAZETTEER_COUNTY','U.S. Census Gazetteer - Counties','GEOGRAPHY','FEDERAL','BULK_FILE','https://www.census.gov/geographies/reference-files/time-series/geo/gazetteer-files.html'),
('CENSUS_GAZETTEER_PLACE','U.S. Census Gazetteer - Places','GEOGRAPHY','FEDERAL','BULK_FILE','https://www.census.gov/geographies/reference-files/time-series/geo/gazetteer-files.html'),
('CENSUS_GAZETTEER_ZCTA','U.S. Census Gazetteer - ZCTAs','GEOGRAPHY','FEDERAL','BULK_FILE','https://www.census.gov/geographies/reference-files/time-series/geo/gazetteer-files.html'),
('HUD_USPS_ZIP_CBSA','HUD-USPS ZIP to CBSA Crosswalk','GEOGRAPHY','FEDERAL_DERIVED_USPS','API','https://www.huduser.gov/portal/dataset/uspszip-api.html'),
('HUD_USPS_ZIP_COUNTY','HUD-USPS ZIP to County Crosswalk','GEOGRAPHY','FEDERAL_DERIVED_USPS','API','https://www.huduser.gov/portal/dataset/uspszip-api.html'),
('CENSUS_ACS5_PROFILE','Census ACS 5-Year Profile','ECONOMICS_DEMAND','FEDERAL','API','https://api.census.gov/data.html'),
('BEA_REGIONAL_RPP','BEA Regional Price Parities','ECONOMICS_PRICE_LEVEL','FEDERAL','API','https://apps.bea.gov/api/'),
('BTS_FAF6_REGIONAL','BTS Freight Analysis Framework 6 - Regional','LOGISTICS_FREIGHT','FEDERAL','BULK_FILE','https://www.bts.gov/faf')
ON CONFLICT(source_key) DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zsl_ingest_worker') THEN
    GRANT USAGE ON SCHEMA zsl,zsl_raw TO zsl_ingest_worker;
    GRANT SELECT,INSERT ON zsl.source_registry,zsl.source_releases,zsl.ingest_runs,zsl.source_artifacts,
      zsl.release_record_memberships,zsl.ingest_attempts,zsl.schema_validation_runs TO zsl_ingest_worker;
    GRANT SELECT,INSERT ON zsl_raw.raw_records TO zsl_ingest_worker;
    GRANT EXECUTE ON FUNCTION zsl.transition_ingest_state(uuid,text) TO zsl_ingest_worker;
    GRANT EXECUTE ON FUNCTION zsl.append_audit_event(text,text,jsonb) TO zsl_ingest_worker;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zsl_reader') THEN
    GRANT USAGE ON SCHEMA zsl TO zsl_reader;
    GRANT SELECT ON zsl.certified_release_records TO zsl_reader;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zsl_certifier') THEN
    GRANT USAGE ON SCHEMA zsl TO zsl_certifier;
    GRANT SELECT ON ALL TABLES IN SCHEMA zsl TO zsl_certifier;
    GRANT INSERT ON zsl.certification_runs TO zsl_certifier;
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'Grant hardening skipped: insufficient privilege; apply grants using Supabase database owner.';
END $$;

COMMIT;
