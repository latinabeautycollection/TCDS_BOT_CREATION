BEGIN;
CREATE TABLE IF NOT EXISTS zsl.zsl2_normalization_runs(
  normalization_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  engine_version text NOT NULL DEFAULT 'zsl2-v2.1.0',
  policy_version text NOT NULL,
  policy_sha256 text NOT NULL CHECK(policy_sha256 ~ '^[0-9a-f]{64}$'),
  package_sha256 text NOT NULL CHECK(package_sha256 ~ '^[0-9a-f]{64}$'),
  git_sha text,
  actor_id text NOT NULL,
  state text NOT NULL CHECK(state IN('STARTED','NORMALIZED','RECONCILED','FAILED')),
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(evidence)='object'),
  evidence_sha256 text CHECK(evidence_sha256 IS NULL OR evidence_sha256 ~ '^[0-9a-f]{64}$')
);
CREATE TABLE IF NOT EXISTS zsl.zsl2_source_bindings(
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  source_key text NOT NULL,
  release_id uuid NOT NULL,
  release_key text NOT NULL,
  ingest_run_id uuid NOT NULL,
  certification_run_id uuid NOT NULL,
  certification_created_at timestamptz NOT NULL,
  PRIMARY KEY(normalization_run_id,source_key),
  UNIQUE(normalization_run_id,release_id)
);
CREATE TABLE IF NOT EXISTS zsl.zsl2_record_lineage(
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  source_key text NOT NULL,
  release_id uuid NOT NULL,
  ingest_run_id uuid NOT NULL,
  raw_record_id uuid NOT NULL,
  raw_record_sha256 text NOT NULL CHECK(raw_record_sha256 ~ '^[0-9a-f]{64}$'),
  canonical_location_id uuid REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  canonical_relationship_id uuid REFERENCES zsl.location_relationships(relationship_id) ON DELETE RESTRICT,
  disposition text NOT NULL CHECK(disposition IN('NORMALIZED_LOCATION','NORMALIZED_RELATIONSHIP','DUPLICATE_EQUIVALENT','QUARANTINED','IGNORED_BY_POLICY')),
  disposition_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK((canonical_location_id IS NOT NULL)::int + (canonical_relationship_id IS NOT NULL)::int <= 1),
  PRIMARY KEY(normalization_run_id,source_key,raw_record_id)
);
CREATE TABLE IF NOT EXISTS zsl.zsl2_conflicts(
  conflict_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  conflict_code text NOT NULL,
  severity text NOT NULL CHECK(severity IN('INFO','WARN','FATAL')),
  entity_key text,
  source_key text,
  details jsonb NOT NULL CHECK(jsonb_typeof(details)='object'),
  details_sha256 text NOT NULL CHECK(details_sha256 ~ '^[0-9a-f]{64}$'),
  resolved boolean NOT NULL DEFAULT false,
  resolution jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);
CREATE INDEX IF NOT EXISTS ix_zsl2_conflicts_open ON zsl.zsl2_conflicts(severity,resolved) WHERE NOT resolved;

CREATE OR REPLACE VIEW zsl.zsl2_current_source_certifications AS
WITH latest_cert AS (
  SELECT DISTINCT ON (ir.release_id)
    s.source_key,sr.release_id,sr.release_key,sr.source_year,sr.source_quarter,sr.discovered_at,
    ir.ingest_run_id,cr.certification_run_id,cr.created_at,cr.status
  FROM zsl.source_registry s
  JOIN zsl.source_releases sr ON sr.source_id=s.source_id
  JOIN zsl.ingest_runs ir ON ir.release_id=sr.release_id AND ir.state='RECONCILED'
  JOIN zsl.certification_runs cr ON cr.ingest_run_id=ir.ingest_run_id
  ORDER BY ir.release_id,cr.created_at DESC
), certified AS (
  SELECT * FROM latest_cert WHERE status='CERTIFIED'
)
SELECT * FROM certified;

CREATE OR REPLACE FUNCTION zsl.zsl2_assert_required_sources_certified(p_sources text[])
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE k text;
BEGIN
  FOREACH k IN ARRAY p_sources LOOP
    IF NOT EXISTS(SELECT 1 FROM zsl.zsl2_current_source_certifications WHERE source_key=k) THEN
      RAISE EXCEPTION 'ZSL2_REQUIRED_SOURCE_NOT_CERTIFIED:%',k;
    END IF;
  END LOOP;
END $$;
COMMIT;
