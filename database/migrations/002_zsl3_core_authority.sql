BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
CREATE TABLE IF NOT EXISTS zsl.zsl3_build_runs(
  build_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  engine_version text NOT NULL CHECK(engine_version='zsl3-v2.2.0'),
  package_sha256 text NOT NULL CHECK(package_sha256 ~ '^[0-9a-f]{64}$'),
  git_sha text NOT NULL,
  source_policy_sha256 text NOT NULL CHECK(source_policy_sha256 ~ '^[0-9a-f]{64}$'),
  feature_policy_sha256 text NOT NULL CHECK(feature_policy_sha256 ~ '^[0-9a-f]{64}$'),
  confidence_policy_sha256 text NOT NULL CHECK(confidence_policy_sha256 ~ '^[0-9a-f]{64}$'),
  freshness_policy_sha256 text NOT NULL CHECK(freshness_policy_sha256 ~ '^[0-9a-f]{64}$'),
  naics_policy_sha256 text NOT NULL CHECK(naics_policy_sha256 ~ '^[0-9a-f]{64}$'),
  certification_policy_sha256 text NOT NULL CHECK(certification_policy_sha256 ~ '^[0-9a-f]{64}$'),
  source_manifest_sha256 text NOT NULL CHECK(source_manifest_sha256 ~ '^[0-9a-f]{64}$'),
  migration_manifest_sha256 text NOT NULL CHECK(migration_manifest_sha256 ~ '^[0-9a-f]{64}$'),
  feature_registry_sha256 text NOT NULL CHECK(feature_registry_sha256 ~ '^[0-9a-f]{64}$'),
  dependency_tree_sha256 text NOT NULL CHECK(dependency_tree_sha256 ~ '^[0-9a-f]{64}$'),
  zsl2_normalization_run_id uuid NOT NULL,
  zsl2_certification_run_id uuid NOT NULL,
  state text NOT NULL CHECK(state IN('CREATED','BINDING','NORMALIZING','VALIDATING','DERIVING','SNAPSHOTTING','REPLAYING','RECONCILED','FAILED')),
  started_at timestamptz NOT NULL DEFAULT now(), completed_at timestamptz,
  failure_stage text, failure_class text, failure_error_redacted text,
  failure_evidence jsonb, failure_evidence_sha256 text CHECK(failure_evidence_sha256 IS NULL OR failure_evidence_sha256 ~ '^[0-9a-f]{64}$'),
  created_by text NOT NULL DEFAULT current_user,
  CHECK(failure_evidence IS NULL OR jsonb_typeof(failure_evidence)='object')
);
CREATE INDEX IF NOT EXISTS ix_zsl3_build_state ON zsl.zsl3_build_runs(state,started_at DESC);

CREATE TABLE IF NOT EXISTS zsl.zsl3_source_bindings(
  source_binding_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id) ON DELETE RESTRICT,
  source_key text NOT NULL, source_dataset text NOT NULL,
  source_geography text NOT NULL CHECK(source_geography IN('STATE','COUNTY','PLACE','ZCTA','POSTAL_CODE','MSA')),
  release_role text NOT NULL,
  source_vintage text NOT NULL,
  source_year integer, source_quarter integer,
  release_id uuid NOT NULL, release_key text NOT NULL,
  ingest_run_id uuid NOT NULL, certification_run_id uuid NOT NULL,
  upstream_package_sha256 text NOT NULL CHECK(upstream_package_sha256 ~ '^[0-9a-f]{64}$'),
  binding_document jsonb NOT NULL CHECK(jsonb_typeof(binding_document)='object'),
  binding_sha256 text NOT NULL CHECK(binding_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(build_run_id,source_dataset,source_geography,release_role)
);
CREATE INDEX IF NOT EXISTS ix_zsl3_bind_source ON zsl.zsl3_source_bindings(build_run_id,source_key,source_geography);

CREATE OR REPLACE FUNCTION zsl.zsl3_transition_build(p_run uuid,p_next text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE cur text; ok boolean:=false;
BEGIN
 SELECT state INTO cur FROM zsl.zsl3_build_runs WHERE build_run_id=p_run FOR UPDATE;
 IF cur IS NULL THEN RAISE EXCEPTION 'ZSL3_BUILD_NOT_FOUND'; END IF;
 ok := CASE
  WHEN cur='CREATED' AND p_next IN('BINDING','FAILED') THEN true
  WHEN cur='BINDING' AND p_next IN('NORMALIZING','FAILED') THEN true
  WHEN cur='NORMALIZING' AND p_next IN('VALIDATING','FAILED') THEN true
  WHEN cur='VALIDATING' AND p_next IN('DERIVING','FAILED') THEN true
  WHEN cur='DERIVING' AND p_next IN('SNAPSHOTTING','FAILED') THEN true
  WHEN cur='SNAPSHOTTING' AND p_next IN('REPLAYING','FAILED') THEN true
  WHEN cur='REPLAYING' AND p_next IN('RECONCILED','FAILED') THEN true
  ELSE false END;
 IF NOT ok THEN RAISE EXCEPTION 'ZSL3_INVALID_BUILD_TRANSITION:%->%',cur,p_next; END IF;
 UPDATE zsl.zsl3_build_runs SET state=p_next, completed_at=CASE WHEN p_next IN('RECONCILED','FAILED') THEN now() ELSE completed_at END WHERE build_run_id=p_run;
END $$;
COMMIT;
