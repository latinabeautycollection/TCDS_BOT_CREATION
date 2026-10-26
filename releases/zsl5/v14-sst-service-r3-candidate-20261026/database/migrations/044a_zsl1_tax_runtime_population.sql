BEGIN;

CREATE TABLE IF NOT EXISTS zsl_tax_acq.runtime_population_runs(
  population_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_kind text NOT NULL CHECK(run_kind IN('SOURCE_ACQUISITION','SOURCE_INGEST','STATE_COVERAGE','NATIONAL_PUBLICATION')),
  state_code char(2),
  source_key text,
  status text NOT NULL CHECK(status IN('CREATED','RUNNING','PASS','FAIL','NOT_EXECUTED')),
  expected_count bigint CHECK(expected_count IS NULL OR expected_count>=0),
  actual_count bigint CHECK(actual_count IS NULL OR actual_count>=0),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(evidence)='object'),
  evidence_sha256 text CHECK(evidence_sha256 IS NULL OR evidence_sha256~'^[0-9a-f]{64}$'),
  package_sha256 text NOT NULL CHECK(package_sha256~'^[0-9a-f]{64}$' AND package_sha256<>repeat('0',64)),
  git_sha text NOT NULL CHECK(git_sha~'^[0-9a-f]{7,64}$'),
  actor text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);
CREATE INDEX IF NOT EXISTS ix_tax_runtime_population_state ON zsl_tax_acq.runtime_population_runs(state_code,run_kind,started_at DESC);

CREATE TABLE IF NOT EXISTS zsl_tax_acq.source_execution_receipts(
  execution_receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  population_run_id uuid NOT NULL REFERENCES zsl_tax_acq.runtime_population_runs(population_run_id) ON DELETE RESTRICT,
  state_code char(2) NOT NULL,
  source_key text NOT NULL,
  authority_url text NOT NULL,
  release_id uuid REFERENCES zsl.source_releases(release_id),
  ingest_run_id uuid REFERENCES zsl.ingest_runs(ingest_run_id),
  certification_run_id uuid REFERENCES zsl.certification_runs(certification_run_id),
  artifact_count integer NOT NULL DEFAULT 0 CHECK(artifact_count>=0),
  record_count bigint NOT NULL DEFAULT 0 CHECK(record_count>=0),
  status text NOT NULL CHECK(status IN('DISCOVERED','DOWNLOADED','INGESTED','CERTIFIED','FAILED','NOT_APPLICABLE')),
  receipt_document jsonb NOT NULL CHECK(jsonb_typeof(receipt_document)='object'),
  receipt_sha256 text NOT NULL CHECK(receipt_sha256~'^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS zsl_tax_acq.state_runtime_readiness(
  state_code char(2) PRIMARY KEY REFERENCES zsl_tax_acq.jurisdiction_registry(state_code),
  family_pass_count integer NOT NULL DEFAULT 0 CHECK(family_pass_count BETWEEN 0 AND 21),
  local_gate_pass boolean NOT NULL DEFAULT false,
  resolution_gate_pass boolean NOT NULL DEFAULT false,
  fatal_conflict_count integer NOT NULL DEFAULT 0 CHECK(fatal_conflict_count>=0),
  ready boolean GENERATED ALWAYS AS (family_pass_count=21 AND local_gate_pass AND resolution_gate_pass AND fatal_conflict_count=0) STORED,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(evidence)='object'),
  evidence_sha256 text CHECK(evidence_sha256 IS NULL OR evidence_sha256~'^[0-9a-f]{64}$'),
  evaluated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION zsl_tax_acq.refresh_state_runtime_readiness(p_state char(2)) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl,zsl_tax_acq AS $$
DECLARE fam integer; loc boolean; res boolean; fatal integer; doc jsonb;
BEGIN
 SELECT count(*)::int INTO fam FROM zsl_tax_acq.family_coverage_attestations WHERE state_code=p_state AND status='PASS';
 SELECT coalesce(status='PASS',false) INTO loc FROM zsl_tax_acq.local_authority_coverage WHERE state_code=p_state;
 SELECT coalesce(status='PASS',false) INTO res FROM zsl_tax_acq.address_resolution_quality WHERE state_code=p_state;
 SELECT count(*)::int INTO fatal FROM zsl_tax_acq.conflicts cf WHERE cf.severity='FATAL' AND cf.resolved=false AND EXISTS(SELECT 1 FROM zsl_tax_acq.canonical_records cr WHERE cr.ingest_run_id=cf.ingest_run_id AND cr.state_code=p_state);
 doc:=jsonb_build_object('state_code',p_state,'family_pass_count',fam,'local_gate_pass',coalesce(loc,false),'resolution_gate_pass',coalesce(res,false),'fatal_conflict_count',fatal);
 INSERT INTO zsl_tax_acq.state_runtime_readiness(state_code,family_pass_count,local_gate_pass,resolution_gate_pass,fatal_conflict_count,evidence,evidence_sha256,evaluated_at)
 VALUES(p_state,fam,coalesce(loc,false),coalesce(res,false),fatal,doc,encode(extensions.digest(convert_to(doc::text,'UTF8'),'sha256'),'hex'),now())
 ON CONFLICT(state_code) DO UPDATE SET family_pass_count=excluded.family_pass_count,local_gate_pass=excluded.local_gate_pass,resolution_gate_pass=excluded.resolution_gate_pass,fatal_conflict_count=excluded.fatal_conflict_count,evidence=excluded.evidence,evidence_sha256=excluded.evidence_sha256,evaluated_at=excluded.evaluated_at;
END $$;

COMMIT;
