BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;

CREATE TABLE IF NOT EXISTS zsl.zsl2_zsl1_authority_decisions_v214(
  decision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  zsl1_package_sha256 text NOT NULL CHECK(zsl1_package_sha256 ~ '^[0-9a-f]{64}$'),
  authority_model text NOT NULL CHECK(authority_model='CERTIFIED_RELEASE_VIEW'),
  governed_release_count integer NOT NULL CHECK(governed_release_count=13),
  certified_release_population_sha256 text NOT NULL CHECK(certified_release_population_sha256 ~ '^[0-9a-f]{64}$'),
  signer_identity text NOT NULL,
  public_key_sha256 text NOT NULL CHECK(public_key_sha256 ~ '^[0-9a-f]{64}$'),
  decision_payload_sha256 text NOT NULL CHECK(decision_payload_sha256 ~ '^[0-9a-f]{64}$'),
  signature_sha256 text NOT NULL CHECK(signature_sha256 ~ '^[0-9a-f]{64}$'),
  checked_at timestamptz NOT NULL,
  verified_at timestamptz NOT NULL DEFAULT now(),
  evidence jsonb NOT NULL,
  UNIQUE(normalization_run_id,decision_payload_sha256)
);

CREATE OR REPLACE FUNCTION zsl.zsl2_zsl1_authority_population_sha_v214(p_package_sha text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl,extensions AS $$
WITH current_cert AS (
  SELECT DISTINCT ON (cr.ingest_run_id) cr.ingest_run_id,cr.certification_run_id,cr.status,cr.created_at
  FROM zsl.certification_runs cr ORDER BY cr.ingest_run_id,cr.created_at DESC
), effective AS (
  SELECT DISTINCT cr.source_key,cr.release_id,cr.ingest_run_id,cc.certification_run_id,ir.package_sha256
  FROM zsl.certified_release_records cr
  JOIN zsl.ingest_runs ir ON ir.ingest_run_id=cr.ingest_run_id
  JOIN current_cert cc ON cc.ingest_run_id=cr.ingest_run_id AND cc.status='CERTIFIED'
  WHERE ir.package_sha256=p_package_sha
)
SELECT encode(digest(convert_to(coalesce(string_agg(
 concat_ws('|',source_key,release_id::text,ingest_run_id::text,certification_run_id::text,package_sha256),E'\n' ORDER BY source_key,release_id,ingest_run_id
),''),'UTF8'),'sha256'),'hex') FROM effective
$$;

CREATE OR REPLACE FUNCTION zsl.zsl2_zsl1_authority_release_count_v214(p_package_sha text)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
 SELECT count(DISTINCT (cr.source_key,cr.release_id))::integer
 FROM zsl.certified_release_records cr JOIN zsl.ingest_runs ir ON ir.ingest_run_id=cr.ingest_run_id
 WHERE ir.package_sha256=p_package_sha
$$;

CREATE OR REPLACE FUNCTION zsl.zsl2_zsl1_authority_decision_current_v214(p_run uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
 SELECT EXISTS(
  SELECT 1 FROM zsl.zsl2_zsl1_authority_decisions_v214 d
  WHERE d.normalization_run_id=p_run
    AND d.zsl1_package_sha256='8565bda4f631f56e8f9aa1db6982144182a7076027cc77811e9398bc5a29a43c'
    AND d.governed_release_count=13
    AND d.certified_release_population_sha256=zsl.zsl2_zsl1_authority_population_sha_v214(d.zsl1_package_sha256)
    AND zsl.zsl2_zsl1_authority_release_count_v214(d.zsl1_package_sha256)=13
 )
$$;

CREATE OR REPLACE FUNCTION zsl.zsl2_v214_authority_immutable() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$ BEGIN RAISE EXCEPTION 'ZSL2_V214_AUTHORITY_EVIDENCE_IMMUTABLE'; END $$;
DROP TRIGGER IF EXISTS trg_zsl2_zsl1_authority_decision_v214_immutable ON zsl.zsl2_zsl1_authority_decisions_v214;
CREATE TRIGGER trg_zsl2_zsl1_authority_decision_v214_immutable BEFORE UPDATE OR DELETE ON zsl.zsl2_zsl1_authority_decisions_v214 FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_v214_authority_immutable();

REVOKE ALL ON zsl.zsl2_zsl1_authority_decisions_v214 FROM PUBLIC;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_certifier') THEN GRANT SELECT,INSERT ON zsl.zsl2_zsl1_authority_decisions_v214 TO zsl2_certifier; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_runtime_tester') THEN GRANT SELECT,INSERT ON zsl.zsl2_zsl1_authority_decisions_v214 TO zsl2_runtime_tester; END IF;
END $$;

COMMIT;
