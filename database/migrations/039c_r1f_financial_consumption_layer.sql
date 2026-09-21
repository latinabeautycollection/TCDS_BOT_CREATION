-- TCDS Retail R1F V2.1 Financial Consumption Layer
-- Provider-authoritative Bright Data cost evidence, deterministic attribution,
-- immutable reconciliation, and fact-ingest integration.

BEGIN;

DO $$
BEGIN
  IF to_regclass('retail.r1f_v2_state') IS NULL THEN
    RAISE EXCEPTION 'R1F financial consumption layer requires R1F V2';
  END IF;
END $$;

CREATE TABLE retail.r1f_financial_consumption_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  layer_version text NOT NULL,
  provider_contract text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO retail.r1f_financial_consumption_state(
  singleton,layer_version,provider_contract
) VALUES(
  true,'1.0.0','BRIGHT_DATA_ZONE_COST_V1'
);

CREATE TABLE retail.r1f_provider_cost_evidence(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL CHECK(provider IN('BRIGHT_DATA')),
  service_type text NOT NULL CHECK(service_type IN(
    'RESIDENTIAL_PROXY','DATACENTER_PROXY','ISP_PROXY','MOBILE_PROXY',
    'UNLOCKER','OTHER_ZONE_SERVICE'
  )),
  source_endpoint text NOT NULL CHECK(source_endpoint='/zone/cost'),
  zone_name text NOT NULL CHECK(length(btrim(zone_name))>0),
  period_from date NOT NULL,
  period_to_exclusive date NOT NULL,
  http_status integer NOT NULL CHECK(http_status BETWEEN 200 AND 299),
  authoritative_for_billing boolean NOT NULL DEFAULT true,
  raw_payload jsonb NOT NULL CHECK(jsonb_typeof(raw_payload)='object'),
  raw_payload_sha256 text NOT NULL CHECK(raw_payload_sha256 ~ '^[0-9a-f]{64}$'),
  request_fingerprint_sha256 text NOT NULL CHECK(request_fingerprint_sha256 ~ '^[0-9a-f]{64}$'),
  retrieved_at timestamptz NOT NULL DEFAULT now(),
  source_process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text,
  CHECK(period_to_exclusive>period_from),
  UNIQUE(provider,zone_name,period_from,period_to_exclusive,raw_payload_sha256)
);

CREATE TABLE retail.r1f_provider_cost_buckets(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_id uuid NOT NULL REFERENCES retail.r1f_provider_cost_evidence(id) ON DELETE RESTRICT,
  bucket_key text NOT NULL CHECK(length(btrim(bucket_key))>0),
  bandwidth_bytes bigint NOT NULL CHECK(bandwidth_bytes>=0),
  billed_cost_usd numeric(18,8) NOT NULL CHECK(billed_cost_usd>=0),
  bucket_document jsonb NOT NULL CHECK(jsonb_typeof(bucket_document)='object'),
  bucket_sha256 text NOT NULL CHECK(bucket_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(evidence_id,bucket_key)
);

CREATE TABLE retail.r1f_provider_job_cost_bindings(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_id uuid NOT NULL REFERENCES retail.r1f_provider_cost_evidence(id) ON DELETE RESTRICT,
  bucket_id uuid NOT NULL REFERENCES retail.r1f_provider_cost_buckets(id) ON DELETE RESTRICT,
  r1d_job_id uuid NOT NULL REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  zone_name text NOT NULL,
  attribution_basis text NOT NULL CHECK(attribution_basis IN(
    'RECORDS_COLLECTED','RECORDS_REQUESTED','EQUAL_SHARE','EXPLICIT_WEIGHT'
  )),
  attribution_weight numeric(30,8) NOT NULL CHECK(attribution_weight>0),
  binding_document jsonb NOT NULL CHECK(jsonb_typeof(binding_document)='object'),
  binding_sha256 text NOT NULL CHECK(binding_sha256 ~ '^[0-9a-f]{64}$'),
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(evidence_id,bucket_id,r1d_job_id),
  CHECK(zone_name=coalesce(binding_document->>'zone_name',zone_name))
);

CREATE TABLE retail.r1f_provider_job_cost_reconciliations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_id uuid NOT NULL REFERENCES retail.r1f_provider_cost_evidence(id) ON DELETE RESTRICT,
  bucket_id uuid NOT NULL REFERENCES retail.r1f_provider_cost_buckets(id) ON DELETE RESTRICT,
  binding_id uuid NOT NULL REFERENCES retail.r1f_provider_job_cost_bindings(id) ON DELETE RESTRICT,
  r1d_job_id uuid NOT NULL REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  provider_billed_cost_usd numeric(18,8) NOT NULL CHECK(provider_billed_cost_usd>=0),
  provider_bandwidth_bytes bigint NOT NULL CHECK(provider_bandwidth_bytes>=0),
  allocation_numerator numeric(30,8) NOT NULL CHECK(allocation_numerator>0),
  allocation_denominator numeric(30,8) NOT NULL CHECK(allocation_denominator>0),
  allocated_cost_usd numeric(18,8) NOT NULL CHECK(allocated_cost_usd>=0),
  attribution_method text NOT NULL CHECK(attribution_method IN(
    'RECORDS_COLLECTED_PROPORTIONAL','RECORDS_REQUESTED_PROPORTIONAL',
    'EQUAL_SHARE','EXPLICIT_WEIGHT_PROPORTIONAL'
  )),
  reconciliation_status text NOT NULL CHECK(reconciliation_status IN('RECONCILED','ZERO_COST_RECONCILED')),
  reconciliation_document jsonb NOT NULL CHECK(jsonb_typeof(reconciliation_document)='object'),
  reconciliation_sha256 text NOT NULL CHECK(reconciliation_sha256 ~ '^[0-9a-f]{64}$'),
  reconciled_by text NOT NULL,
  reconciled_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(evidence_id,bucket_id,r1d_job_id)
);

CREATE INDEX idx_r1f_provider_cost_evidence_zone_period
ON retail.r1f_provider_cost_evidence(zone_name,period_from,period_to_exclusive);

CREATE INDEX idx_r1f_provider_binding_job
ON retail.r1f_provider_job_cost_bindings(r1d_job_id,created_at DESC);

CREATE INDEX idx_r1f_provider_reconciliation_job
ON retail.r1f_provider_job_cost_reconciliations(r1d_job_id,reconciled_at DESC);

CREATE OR REPLACE FUNCTION retail.r1f_financial_binding_insert_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_zone text;
  v_bucket_evidence uuid;
BEGIN
  SELECT e.zone_name,b.evidence_id
  INTO v_zone,v_bucket_evidence
  FROM retail.r1f_provider_cost_buckets b
  JOIN retail.r1f_provider_cost_evidence e ON e.id=b.evidence_id
  WHERE b.id=NEW.bucket_id;

  IF NOT FOUND OR v_bucket_evidence<>NEW.evidence_id OR v_zone<>NEW.zone_name THEN
    RAISE EXCEPTION 'R1F financial binding evidence/bucket/zone mismatch';
  END IF;

  IF EXISTS(
    SELECT 1 FROM retail.r1f_provider_job_cost_reconciliations r
    WHERE r.evidence_id=NEW.evidence_id AND r.bucket_id=NEW.bucket_id
  ) THEN
    RAISE EXCEPTION 'R1F provider cost bucket already reconciled; bindings are sealed';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_provider_job_bindings_validate
BEFORE INSERT ON retail.r1f_provider_job_cost_bindings
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_binding_insert_guard();

CREATE OR REPLACE FUNCTION retail.r1f_financial_reconciliation_insert_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_binding retail.r1f_provider_job_cost_bindings%ROWTYPE;
  v_bucket retail.r1f_provider_cost_buckets%ROWTYPE;
BEGIN
  SELECT * INTO v_binding
  FROM retail.r1f_provider_job_cost_bindings
  WHERE id=NEW.binding_id;

  SELECT * INTO v_bucket
  FROM retail.r1f_provider_cost_buckets
  WHERE id=NEW.bucket_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1F financial reconciliation bucket missing';
  END IF;

  IF v_binding.id IS NULL
     OR v_binding.evidence_id<>NEW.evidence_id
     OR v_binding.bucket_id<>NEW.bucket_id
     OR v_binding.r1d_job_id<>NEW.r1d_job_id THEN
    RAISE EXCEPTION 'R1F financial reconciliation binding mismatch';
  END IF;

  IF v_bucket.evidence_id<>NEW.evidence_id
     OR round(v_bucket.billed_cost_usd,8)<>round(NEW.provider_billed_cost_usd,8)
     OR v_bucket.bandwidth_bytes<>NEW.provider_bandwidth_bytes THEN
    RAISE EXCEPTION 'R1F financial reconciliation provider authority mismatch';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_provider_job_reconciliation_validate
BEFORE INSERT ON retail.r1f_provider_job_cost_reconciliations
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_reconciliation_insert_guard();

CREATE OR REPLACE FUNCTION retail.r1f_financial_append_only_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1F financial evidence/reconciliation rows are append-only';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_provider_cost_evidence_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_provider_cost_evidence
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_append_only_guard();

CREATE TRIGGER trg_r1f_provider_cost_buckets_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_provider_cost_buckets
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_append_only_guard();

CREATE TRIGGER trg_r1f_provider_job_bindings_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_provider_job_cost_bindings
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_append_only_guard();

CREATE TRIGGER trg_r1f_provider_job_reconciliations_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_provider_job_cost_reconciliations
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_append_only_guard();

CREATE OR REPLACE VIEW retail.r1f_effective_provider_job_cost AS
SELECT DISTINCT ON (r.r1d_job_id)
  r.r1d_job_id,
  r.id reconciliation_id,
  r.evidence_id,
  r.bucket_id,
  e.provider,
  e.service_type,
  e.zone_name,
  e.period_from,
  e.period_to_exclusive,
  b.bucket_key,
  b.bandwidth_bytes provider_bandwidth_bytes,
  b.billed_cost_usd provider_billed_cost_usd,
  r.allocated_cost_usd,
  r.attribution_method,
  r.reconciliation_status,
  r.reconciliation_sha256,
  r.reconciled_at
FROM retail.r1f_provider_job_cost_reconciliations r
JOIN retail.r1f_provider_cost_evidence e ON e.id=r.evidence_id
JOIN retail.r1f_provider_cost_buckets b ON b.id=r.bucket_id
WHERE e.authoritative_for_billing=true
  AND r.reconciliation_status IN('RECONCILED','ZERO_COST_RECONCILED')
ORDER BY r.r1d_job_id,r.reconciled_at DESC,r.id DESC;

ALTER TABLE retail.r1f_job_facts
  ADD COLUMN cost_authority text,
  ADD COLUMN provider_cost_evidence_id uuid REFERENCES retail.r1f_provider_cost_evidence(id) ON DELETE RESTRICT,
  ADD COLUMN provider_cost_reconciliation_id uuid REFERENCES retail.r1f_provider_job_cost_reconciliations(id) ON DELETE RESTRICT,
  ADD COLUMN provider_zone_name text,
  ADD COLUMN cost_attribution_method text,
  ADD COLUMN provider_billed_cost_usd numeric(18,8),
  ADD COLUMN provider_bandwidth_bytes bigint,
  ADD COLUMN provider_cost_reconciled_at timestamptz;

UPDATE retail.r1f_job_facts
SET cost_authority=CASE WHEN cost_basis='actual' THEN 'R1D_DIRECT' ELSE 'ESTIMATE' END
WHERE cost_authority IS NULL;

ALTER TABLE retail.r1f_job_facts
  ALTER COLUMN cost_authority SET NOT NULL,
  ADD CONSTRAINT r1f_job_cost_authority_check CHECK(cost_authority IN(
    'R1D_DIRECT','BRIGHT_DATA_ZONE_COST','ESTIMATE'
  )),
  ADD CONSTRAINT r1f_job_provider_cost_nonnegative CHECK(
    provider_billed_cost_usd IS NULL OR provider_billed_cost_usd>=0
  ),
  ADD CONSTRAINT r1f_job_provider_bw_nonnegative CHECK(
    provider_bandwidth_bytes IS NULL OR provider_bandwidth_bytes>=0
  );

CREATE OR REPLACE FUNCTION retail.r1f_financial_fact_integration()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  r retail.r1f_effective_provider_job_cost%ROWTYPE;
BEGIN
  IF TG_OP='INSERT' THEN
    SELECT * INTO r
    FROM retail.r1f_effective_provider_job_cost
    WHERE r1d_job_id=NEW.r1d_job_id;

    IF FOUND THEN
      NEW.actual_cost_usd:=r.allocated_cost_usd;
      NEW.cost_basis:='actual';
      NEW.actual_cost_coverage:=1;
      NEW.cost_authority:='BRIGHT_DATA_ZONE_COST';
      NEW.provider_cost_evidence_id:=r.evidence_id;
      NEW.provider_cost_reconciliation_id:=r.reconciliation_id;
      NEW.provider_zone_name:=r.zone_name;
      NEW.cost_attribution_method:=r.attribution_method;
      NEW.provider_billed_cost_usd:=r.provider_billed_cost_usd;
      NEW.provider_bandwidth_bytes:=r.provider_bandwidth_bytes;
      NEW.provider_cost_reconciled_at:=r.reconciled_at;
    ELSIF NEW.cost_basis='actual' THEN
      NEW.cost_authority:='R1D_DIRECT';
    ELSE
      NEW.cost_authority:='ESTIMATE';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP='UPDATE'
     AND current_setting('r1f.fact_finalize',true)='true' THEN
    NEW.fact_document:=NEW.fact_document || jsonb_build_object(
      'search_cost_usd',NEW.actual_cost_usd,
      'cost_basis',NEW.cost_basis,
      'financial_cost',jsonb_build_object(
        'authority',NEW.cost_authority,
        'provider_cost_evidence_id',NEW.provider_cost_evidence_id,
        'provider_cost_reconciliation_id',NEW.provider_cost_reconciliation_id,
        'provider_zone_name',NEW.provider_zone_name,
        'attribution_method',NEW.cost_attribution_method,
        'provider_billed_cost_usd',NEW.provider_billed_cost_usd,
        'provider_bandwidth_bytes',NEW.provider_bandwidth_bytes,
        'provider_cost_reconciled_at',NEW.provider_cost_reconciled_at
      )
    );
    NEW.fact_sha256:=retail.r1f_sha256_jsonb(NEW.fact_document);
    RETURN NEW;
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_00_financial_fact_integration
BEFORE INSERT OR UPDATE ON retail.r1f_job_facts
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_fact_integration();

CREATE OR REPLACE FUNCTION retail.r1f_validate_certification_policy(
  p_policy jsonb
)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_class text;
  v_required jsonb:='{
    "high_opportunity":75,
    "low_opportunity":75,
    "insufficient_sample":75,
    "high_cost":75,
    "strong_bargain":75,
    "weak_availability":75,
    "exploration":50,
    "nationwide_ranking":50,
    "strategy_convergence":50
  }'::jsonb;
BEGIN
  IF p_policy IS NULL OR jsonb_typeof(p_policy)<>'object' THEN
    RAISE EXCEPTION 'R1F certification policy must be object';
  END IF;

  IF COALESCE((p_policy->>'minimum_total_fixtures')::int,0)<625
     OR COALESCE((p_policy->>'minimum_e2e_scenarios')::int,0)<10
     OR COALESCE((p_policy->>'minimum_e2e_jobs')::int,0)<50
     OR COALESCE((p_policy->>'minimum_e2e_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_score_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_recommendation_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_ranking_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_convergence_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_replay_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_fact_hash_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_snapshot_hash_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_recommendation_hash_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_actual_cost_coverage_pct')::numeric,-1)<80
     OR COALESCE((p_policy->>'minimum_provider_reconciled_cost_coverage_pct')::numeric,-1)<80
     OR COALESCE((p_policy->>'minimum_provider_reconciliation_balance_pct')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_local_timezone_coverage_pct')::numeric,-1)<95 THEN
    RAISE EXCEPTION 'R1F V2.1 certification policy weaker than Green Tier 1';
  END IF;

  IF jsonb_typeof(COALESCE(p_policy->'class_minimums','{}'::jsonb))<>'object' THEN
    RAISE EXCEPTION 'R1F V2.1 class_minimums must be object';
  END IF;

  FOR v_class IN SELECT jsonb_object_keys(v_required)
  LOOP
    IF COALESCE((p_policy#>>ARRAY['class_minimums',v_class])::int,0)
       < (v_required->>v_class)::int THEN
      RAISE EXCEPTION 'R1F V2.1 class % minimum below Green Tier floor %',
        v_class,(v_required->>v_class)::int;
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE VIEW retail.r1f_financial_consumption_status AS
WITH f AS (
  SELECT
    count(*)::int total_jobs,
    count(*) FILTER(where cost_basis in('actual','allocated_provider'))::int actual_cost_jobs,
    count(*) FILTER(where cost_authority='BRIGHT_DATA_ZONE_COST')::int provider_reconciled_jobs,
    count(*) FILTER(where cost_authority='ESTIMATE')::int estimated_jobs,
    coalesce(sum(actual_cost_usd),0)::numeric total_effective_cost_usd,
    coalesce(sum(actual_cost_usd) FILTER(where cost_authority='BRIGHT_DATA_ZONE_COST'),0)::numeric provider_allocated_cost_usd
  FROM retail.r1f_job_facts
  WHERE engine_version='r1f-v2.0.0'
), e AS (
  SELECT count(*)::int evidence_records
  FROM retail.r1f_provider_cost_evidence
), r AS (
  SELECT count(*)::int reconciliations
  FROM retail.r1f_provider_job_cost_reconciliations
)
SELECT f.*,e.evidence_records,r.reconciliations,
  CASE WHEN f.total_jobs=0 THEN 0
       ELSE round(100.0*f.provider_reconciled_jobs/f.total_jobs,4) END provider_reconciled_coverage_pct
FROM f CROSS JOIN e CROSS JOIN r;

GRANT SELECT ON retail.r1f_provider_cost_evidence TO retail_r1f_reader,retail_r1f_certifier;
GRANT SELECT ON retail.r1f_provider_cost_buckets TO retail_r1f_reader,retail_r1f_certifier;
GRANT SELECT ON retail.r1f_provider_job_cost_bindings TO retail_r1f_reader,retail_r1f_certifier;
GRANT SELECT ON retail.r1f_provider_job_cost_reconciliations TO retail_r1f_reader,retail_r1f_certifier;
GRANT SELECT ON retail.r1f_effective_provider_job_cost TO retail_r1f_reader,retail_r1f_worker,retail_r1f_certifier;
GRANT SELECT ON retail.r1f_financial_consumption_status TO retail_r1f_reader,retail_r1f_certifier;

GRANT INSERT ON retail.r1f_provider_cost_evidence TO retail_r1f_worker;
GRANT INSERT ON retail.r1f_provider_cost_buckets TO retail_r1f_worker;
GRANT INSERT ON retail.r1f_provider_job_cost_bindings TO retail_r1f_worker;
GRANT INSERT ON retail.r1f_provider_job_cost_reconciliations TO retail_r1f_worker;

COMMIT;
