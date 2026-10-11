BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;

CREATE TABLE IF NOT EXISTS zsl.zsl2_territorial_pending_evidence_v214(
  pending_evidence_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  source_key text NOT NULL CHECK(source_key='HUD_USPS_ZIP_COUNTY'),
  release_id uuid NOT NULL,
  ingest_run_id uuid NOT NULL,
  raw_record_id uuid NOT NULL,
  raw_record_sha256 text NOT NULL CHECK(raw_record_sha256 ~ '^[0-9a-f]{64}$'),
  postal_code text NOT NULL CHECK(postal_code ~ '^[0-9]{5}$'),
  territorial_county_geoid text NOT NULL CHECK(territorial_county_geoid ~ '^(60|66|69|72|78)[0-9]{3}$'),
  expected_parent_canonical_key text NOT NULL,
  authority_status text NOT NULL DEFAULT 'PENDING_EXTERNAL_AUTHORITY' CHECK(authority_status='PENDING_EXTERNAL_AUTHORITY'),
  policy_version text NOT NULL DEFAULT 'TCDS_ZSL2_TERRITORIAL_PENDING_V2_1_4',
  evidence jsonb NOT NULL,
  evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(normalization_run_id,source_key,raw_record_id,expected_parent_canonical_key)
);
CREATE INDEX IF NOT EXISTS ix_zsl2_territorial_pending_run ON zsl.zsl2_territorial_pending_evidence_v214(normalization_run_id,source_key);

CREATE OR REPLACE FUNCTION zsl.zsl2_v214_evidence_immutable() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$ BEGIN RAISE EXCEPTION 'ZSL2_V214_EVIDENCE_IMMUTABLE'; END $$;
DROP TRIGGER IF EXISTS trg_zsl2_territorial_pending_v214_immutable ON zsl.zsl2_territorial_pending_evidence_v214;
CREATE TRIGGER trg_zsl2_territorial_pending_v214_immutable BEFORE UPDATE OR DELETE ON zsl.zsl2_territorial_pending_evidence_v214 FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_v214_evidence_immutable();

REVOKE ALL ON zsl.zsl2_territorial_pending_evidence_v214 FROM PUBLIC;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_normalizer') THEN GRANT SELECT,INSERT ON zsl.zsl2_territorial_pending_evidence_v214 TO zsl2_normalizer; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_certifier') THEN GRANT SELECT ON zsl.zsl2_territorial_pending_evidence_v214 TO zsl2_certifier; END IF;
END $$;

COMMIT;
