BEGIN;

CREATE SCHEMA IF NOT EXISTS retail;
CREATE SCHEMA IF NOT EXISTS retail_audit;

-- ============================================================================
-- TCDS RETAIL R1F — SEARCH INTELLIGENCE, COST/YIELD & GEO OPTIMIZATION
-- GREEN TIER 1 HARDENED V1 FREEZE CANDIDATE
--
-- R1F OWNS:
--   search performance facts
--   cost/yield intelligence
--   product × retailer × geography × time learning
--   retailer/ZIP/store opportunity scores
--   bargain-relative price intelligence
--   search-frequency / geographic-expansion recommendations
--   exploration vs exploitation controls
--   immutable recommendation evidence
--
-- R1F DOES NOT OWN:
--   scraper contracts
--   route creation
--   direct R1D scheduling/activation
--   demand authority
--   profitability / ROI
--   capital
--   BUY / NO-BUY
--   purchasing / checkout
-- ============================================================================

DO $$
DECLARE
  v_r1e record;
BEGIN
  IF to_regclass('retail.r1e_v21_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1e_v21_state
       WHERE singleton=true AND hardening_version='2.1.0'
     ) THEN
    RAISE EXCEPTION 'R1F requires R1E V2.1 hardening 2.1.0';
  END IF;

  IF to_regclass('retail.r1e_certification_runs') IS NULL THEN
    RAISE EXCEPTION 'R1F requires R1E certification authority';
  END IF;

  SELECT * INTO v_r1e
  FROM retail.r1e_certification_runs
  WHERE completed_at IS NOT NULL
  ORDER BY completed_at DESC,id::text DESC
  LIMIT 1;

  IF NOT FOUND
     OR v_r1e.certification_status<>'CERTIFIED'
     OR v_r1e.certification_version<>'r1e-v2.1.0' THEN
    RAISE EXCEPTION 'R1F requires latest R1E = r1e-v2.1.0 CERTIFIED';
  END IF;

  IF to_regclass('retail.r1d_dispatch_jobs') IS NULL
     OR to_regclass('retail.r1d_dispatch_attempts') IS NULL
     OR to_regclass('retail.r1e_qualification_results') IS NULL
     OR to_regclass('retail.r1e_effective_qualified_products') IS NULL THEN
    RAISE EXCEPTION 'R1F upstream execution/qualification dependencies missing';
  END IF;

  IF to_regclass('arb.process_registry') IS NULL
     OR to_regclass('arb.process_runs') IS NULL
     OR to_regclass('retail_audit.retail_change_log') IS NULL THEN
    RAISE EXCEPTION 'R1F provenance/audit dependencies missing';
  END IF;
END $$;

CREATE TABLE retail.r1f_schema_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  schema_version text NOT NULL,
  doctrine text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user
);

INSERT INTO retail.r1f_schema_state(singleton,schema_version,doctrine)
VALUES(
  true,'1.0.0',
  'R1F learns search economics and geography from certified R1D/R1E truth. It emits recommendations only and never directly mutates R1D schedule/geo authority or authorizes purchase.'
);

CREATE OR REPLACE FUNCTION retail.r1f_sha256_text(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT retail.r1e_sha256_text(p_text) $$;

CREATE OR REPLACE FUNCTION retail.r1f_sha256_jsonb(p_doc jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT retail.r1f_sha256_text(p_doc::text) $$;


CREATE OR REPLACE FUNCTION retail.r1f_try_numeric(p_text text)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
  IF p_text IS NULL OR btrim(p_text)='' THEN RETURN NULL; END IF;
  RETURN p_text::numeric;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_try_integer(p_text text)
RETURNS integer
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v numeric;
BEGIN
  v:=retail.r1f_try_numeric(p_text);
  IF v IS NULL OR v<>trunc(v) OR v>2147483647 OR v< -2147483648 THEN
    RETURN NULL;
  END IF;
  RETURN v::integer;
END $$;

-- ---------- RBAC -------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1f_reader') THEN
    CREATE ROLE retail_r1f_reader NOLOGIN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1f_worker') THEN
    CREATE ROLE retail_r1f_worker NOLOGIN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1f_certifier') THEN
    CREATE ROLE retail_r1f_certifier NOLOGIN;
  END IF;
END $$;

INSERT INTO arb.process_registry(
  process_name,phase_no,process_group,description,owner_team,active_flag
)
VALUES
('RETAIL_R1F_R1E_BIND',2,'RETAIL_AUTOMATION',
 'Bind R1F to exact latest certified R1E V2.1 authority.',
 'TCDS Retail Automation',true),
('RETAIL_R1F_POLICY_REGISTER',2,'RETAIL_AUTOMATION',
 'Register immutable R1F scoring/recommendation policy.',
 'TCDS Retail Automation',true),
('RETAIL_R1F_INGEST_JOB',2,'RETAIL_AUTOMATION',
 'Materialize immutable search-performance facts from one completed R1D job and current R1E results.',
 'TCDS Retail Automation',true),
('RETAIL_R1F_BUILD_INTELLIGENCE',2,'RETAIL_AUTOMATION',
 'Build geographic retailer/product search-intelligence snapshots.',
 'TCDS Retail Automation',true),
('RETAIL_R1F_RECOMMEND',2,'RETAIL_AUTOMATION',
 'Generate governed R1D search strategy recommendations.',
 'TCDS Retail Automation',true),
('RETAIL_R1F_CERTIFY',2,'RETAIL_AUTOMATION',
 'Execute R1F Green Tier 1 certification.',
 'TCDS Retail Automation',true)
ON CONFLICT(process_name) DO NOTHING;

-- ---------- EXACT R1E BINDING -----------------------------------------------
CREATE TABLE retail.r1f_r1e_certification_binding(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  r1e_certification_run_id uuid NOT NULL
    REFERENCES retail.r1e_certification_runs(id) ON DELETE RESTRICT,
  r1e_certification_version text NOT NULL,
  r1e_package_sha256 text NOT NULL CHECK(r1e_package_sha256 ~ '^[0-9a-f]{64}$'),
  r1e_evidence_manifest_sha256 text NOT NULL CHECK(r1e_evidence_manifest_sha256 ~ '^[0-9a-f]{64}$'),
  r1e_ruleset_id uuid NOT NULL REFERENCES retail.r1e_match_rulesets(id) ON DELETE RESTRICT,
  r1e_ruleset_sha256 text NOT NULL CHECK(r1e_ruleset_sha256 ~ '^[0-9a-f]{64}$'),
  bound_by text NOT NULL,
  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE retail.r1f_r1e_binding_history(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  r1e_certification_run_id uuid NOT NULL REFERENCES retail.r1e_certification_runs(id) ON DELETE RESTRICT,
  r1e_package_sha256 text NOT NULL,
  r1e_evidence_manifest_sha256 text NOT NULL,
  r1e_ruleset_id uuid NOT NULL REFERENCES retail.r1e_match_rulesets(id) ON DELETE RESTRICT,
  r1e_ruleset_sha256 text NOT NULL,
  bound_by text NOT NULL,
  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1f_r1e_binding_is_current()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      b.r1e_certification_version='r1e-v2.1.0'
      AND cr.id=b.r1e_certification_run_id
      AND cr.certification_status='CERTIFIED'
      AND cr.certification_version='r1e-v2.1.0'
      AND cr.id=(
        SELECT x.id
        FROM retail.r1e_certification_runs x
        WHERE x.completed_at IS NOT NULL
        ORDER BY x.completed_at DESC,x.id::text DESC
        LIMIT 1
      )
      AND cr.r1e_package_sha256=b.r1e_package_sha256
      AND cr.evidence_manifest_sha256=b.r1e_evidence_manifest_sha256
      AND cr.ruleset_id=b.r1e_ruleset_id
      AND cr.ruleset_sha256=b.r1e_ruleset_sha256
      AND retail.r1e_latest_certification_is_current(b.r1e_ruleset_id)=true
    FROM retail.r1f_r1e_certification_binding b
    JOIN retail.r1e_certification_runs cr
      ON cr.id=b.r1e_certification_run_id
    WHERE b.singleton=true
  ),false)
$$;

CREATE OR REPLACE FUNCTION retail.r1f_assert_process_run(
  p_run_id uuid,
  p_allowed_processes text[]
)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,arb
AS $$
DECLARE
  r record;
BEGIN
  SELECT process_name,status
  INTO r
  FROM arb.process_runs
  WHERE run_id=p_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1F process run missing';
  END IF;

  IF NOT (r.process_name=ANY(p_allowed_processes)) THEN
    RAISE EXCEPTION 'R1F process family % not allowed',r.process_name;
  END IF;

  IF r.status<>'STARTED' THEN
    RAISE EXCEPTION 'R1F requires STARTED process run, got %',r.status;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_bind_r1e_certification(
  p_r1e_certification_run_id uuid,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  cr record;
  v_latest uuid;
BEGIN
  PERFORM retail.r1f_assert_process_run(
    p_process_run_id,
    ARRAY['RETAIL_R1F_R1E_BIND']
  );

  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  SELECT id INTO v_latest
  FROM retail.r1e_certification_runs
  WHERE completed_at IS NOT NULL
  ORDER BY completed_at DESC,id::text DESC
  LIMIT 1;

  IF v_latest IS DISTINCT FROM p_r1e_certification_run_id THEN
    RAISE EXCEPTION 'R1F bind blocked: supplied R1E certification is not latest';
  END IF;

  SELECT * INTO cr
  FROM retail.r1e_certification_runs
  WHERE id=p_r1e_certification_run_id
    AND certification_status='CERTIFIED'
    AND certification_version='r1e-v2.1.0';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1F bind requires R1E V2.1 CERTIFIED';
  END IF;

  INSERT INTO retail.r1f_r1e_binding_history(
    r1e_certification_run_id,r1e_package_sha256,
    r1e_evidence_manifest_sha256,
    r1e_ruleset_id,r1e_ruleset_sha256,
    bound_by,source_process_run_id,source_correlation_id
  )
  VALUES(
    cr.id,cr.r1e_package_sha256,cr.evidence_manifest_sha256,
    cr.ruleset_id,cr.ruleset_sha256,
    p_actor,p_process_run_id,p_correlation_id
  );

  INSERT INTO retail.r1f_r1e_certification_binding(
    singleton,r1e_certification_run_id,r1e_certification_version,
    r1e_package_sha256,r1e_evidence_manifest_sha256,
    r1e_ruleset_id,r1e_ruleset_sha256,
    bound_by,source_process_run_id,source_correlation_id
  )
  VALUES(
    true,cr.id,'r1e-v2.1.0',
    cr.r1e_package_sha256,cr.evidence_manifest_sha256,
    cr.ruleset_id,cr.ruleset_sha256,
    p_actor,p_process_run_id,p_correlation_id
  )
  ON CONFLICT(singleton) DO UPDATE SET
    r1e_certification_run_id=EXCLUDED.r1e_certification_run_id,
    r1e_certification_version=EXCLUDED.r1e_certification_version,
    r1e_package_sha256=EXCLUDED.r1e_package_sha256,
    r1e_evidence_manifest_sha256=EXCLUDED.r1e_evidence_manifest_sha256,
    r1e_ruleset_id=EXCLUDED.r1e_ruleset_id,
    r1e_ruleset_sha256=EXCLUDED.r1e_ruleset_sha256,
    bound_by=EXCLUDED.bound_by,
    source_process_run_id=EXCLUDED.source_process_run_id,
    source_correlation_id=EXCLUDED.source_correlation_id,
    bound_at=now(),
    updated_at=now();
END $$;

-- ---------- IMMUTABLE INTELLIGENCE POLICY -----------------------------------
CREATE TABLE retail.r1f_intelligence_policies(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_code text NOT NULL,
  policy_version text NOT NULL,
  policy_json jsonb NOT NULL CHECK(jsonb_typeof(policy_json)='object'),
  policy_sha256 text NOT NULL CHECK(policy_sha256 ~ '^[0-9a-f]{64}$'),
  certification_status text NOT NULL DEFAULT 'draft'
    CHECK(certification_status IN('draft','certified','suspended','retired')),
  created_by text NOT NULL,
  certified_by text,
  certification_process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  certification_correlation_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  certified_at timestamptz,
  UNIQUE(policy_code,policy_version)
);

CREATE UNIQUE INDEX uq_r1f_one_certified_policy
ON retail.r1f_intelligence_policies(policy_code)
WHERE certification_status='certified';

CREATE OR REPLACE FUNCTION retail.r1f_prepare_policy()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.policy_sha256:=retail.r1f_sha256_jsonb(NEW.policy_json);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_prepare_policy
BEFORE INSERT OR UPDATE ON retail.r1f_intelligence_policies
FOR EACH ROW EXECUTE FUNCTION retail.r1f_prepare_policy();

CREATE OR REPLACE FUNCTION retail.r1f_policy_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1F policies cannot be deleted';
  END IF;

  IF OLD.certification_status='certified' THEN
    IF (to_jsonb(NEW)-ARRAY['certification_status'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['certification_status']) THEN
      RAISE EXCEPTION 'Certified R1F policy immutable; create new version';
    END IF;
    IF NEW.certification_status NOT IN('certified','suspended','retired') THEN
      RAISE EXCEPTION 'Invalid R1F policy transition';
    END IF;
  END IF;

  IF OLD.certification_status IN('suspended','retired')
     AND NEW.certification_status<>OLD.certification_status
     AND NOT (
       OLD.certification_status='suspended'
       AND NEW.certification_status='retired'
     ) THEN
    RAISE EXCEPTION 'Suspended/retired R1F policy cannot be reactivated';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_policy_guard
BEFORE UPDATE OR DELETE ON retail.r1f_intelligence_policies
FOR EACH ROW EXECUTE FUNCTION retail.r1f_policy_guard();

CREATE OR REPLACE FUNCTION retail.r1f_validate_policy(p_policy jsonb)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_sum numeric;
BEGIN
  IF p_policy IS NULL OR jsonb_typeof(p_policy)<>'object' THEN
    RAISE EXCEPTION 'R1F policy must be JSON object';
  END IF;

  IF COALESCE((p_policy->>'lookback_days')::int,0)<1
     OR COALESCE((p_policy->>'lookback_days')::int,0)>180 THEN
    RAISE EXCEPTION 'lookback_days must be 1..180';
  END IF;

  IF COALESCE((p_policy->>'minimum_sample_jobs')::int,0)<3 THEN
    RAISE EXCEPTION 'minimum_sample_jobs must be >=3';
  END IF;

  IF COALESCE(
       (p_policy->>'max_exploration_recommendations_per_run')::int,
       0
     )<1
     OR COALESCE(
       (p_policy->>'max_exploration_recommendations_per_run')::int,
       1001
     )>1000 THEN
    RAISE EXCEPTION
      'max_exploration_recommendations_per_run must be 1..1000';
  END IF;

  v_sum:=
    COALESCE((p_policy#>>'{score_weights,qualification_yield}')::numeric,0)+
    COALESCE((p_policy#>>'{score_weights,relative_bargain}')::numeric,0)+
    COALESCE((p_policy#>>'{score_weights,cost_efficiency}')::numeric,0)+
    COALESCE((p_policy#>>'{score_weights,availability}')::numeric,0)+
    COALESCE((p_policy#>>'{score_weights,freshness}')::numeric,0);

  IF abs(v_sum-1)>0.0001 THEN
    RAISE EXCEPTION 'R1F score weights must sum to 1';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_certify_policy(
  p_policy_id uuid,
  p_process_run_id uuid,
  p_correlation_id text,
  p_certifier text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  p retail.r1f_intelligence_policies%ROWTYPE;
BEGIN
  PERFORM retail.r1f_assert_process_run(
    p_process_run_id,
    ARRAY['RETAIL_R1F_POLICY_REGISTER']
  );

  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id',p_certifier,true);
  PERFORM set_config('app.actor_name',p_certifier,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  PERFORM pg_advisory_xact_lock(
    hashtextextended('r1f-policy:'||p_policy_id::text,0)
  );

  SELECT * INTO p
  FROM retail.r1f_intelligence_policies
  WHERE id=p_policy_id
  FOR UPDATE;

  IF NOT FOUND OR p.certification_status<>'draft' THEN
    RAISE EXCEPTION 'R1F policy missing/not eligible';
  END IF;

  PERFORM retail.r1f_validate_policy(p.policy_json);

  UPDATE retail.r1f_intelligence_policies
  SET certification_status='suspended'
  WHERE policy_code=p.policy_code
    AND id<>p.id
    AND certification_status='certified';

  UPDATE retail.r1f_intelligence_policies
  SET certification_status='certified',
      certified_by=p_certifier,
      certification_process_run_id=p_process_run_id,
      certification_correlation_id=p_correlation_id,
      certified_at=now()
  WHERE id=p.id;
END $$;

-- ---------- IMMUTABLE SEARCH FACTS ------------------------------------------
CREATE TABLE retail.r1f_job_facts(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  r1d_job_id uuid NOT NULL REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  r1d_attempt_id bigint NOT NULL REFERENCES retail.r1d_dispatch_attempts(id) ON DELETE RESTRICT,
  r1e_certification_run_id uuid NOT NULL REFERENCES retail.r1e_certification_runs(id) ON DELETE RESTRICT,
  r1e_package_sha256 text NOT NULL,
  ruleset_id uuid NOT NULL REFERENCES retail.r1e_match_rulesets(id) ON DELETE RESTRICT,
  ruleset_sha256 text NOT NULL,

  compilation_id uuid NOT NULL REFERENCES retail.search_job_compilations(id) ON DELETE RESTRICT,
  target_id uuid NOT NULL REFERENCES retail.search_targets(id) ON DELETE RESTRICT,
  r1a_revision_id uuid NOT NULL REFERENCES retail.search_target_revisions(id) ON DELETE RESTRICT,
  r1a_revision_hash text NOT NULL CHECK(r1a_revision_hash ~ '^[0-9a-f]{64}$'),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  collection_source_id uuid REFERENCES retail.platform_collection_sources(id) ON DELETE RESTRICT,

  location_context_json jsonb NOT NULL CHECK(jsonb_typeof(location_context_json)='object'),
  location_fingerprint text NOT NULL CHECK(location_fingerprint ~ '^[0-9a-f]{64}$'),
  location_type text,
  location_code text,
  store_code text,
  postal_code text,

  scheduled_for timestamptz,
  completed_at timestamptz NOT NULL,
  weekday_iso integer NOT NULL CHECK(weekday_iso BETWEEN 1 AND 7),
  hour_utc integer NOT NULL CHECK(hour_utc BETWEEN 0 AND 23),

  actual_cost_usd numeric NOT NULL CHECK(actual_cost_usd>=0),
  cost_basis text NOT NULL CHECK(cost_basis IN('actual','estimated')),

  records_requested integer,
  records_collected integer,
  observations_total integer NOT NULL CHECK(observations_total>=0),
  qualified_observations integer NOT NULL CHECK(qualified_observations>=0),
  rejected_identity integer NOT NULL CHECK(rejected_identity>=0),
  rejected_accessory integer NOT NULL CHECK(rejected_accessory>=0),
  rejected_condition integer NOT NULL CHECK(rejected_condition>=0),
  rejected_duplicate integer NOT NULL CHECK(rejected_duplicate>=0),
  rejected_incomplete integer NOT NULL CHECK(rejected_incomplete>=0),

  min_qualified_price numeric,
  median_qualified_price numeric,
  avg_qualified_price numeric,
  in_stock_qualified integer NOT NULL DEFAULT 0 CHECK(in_stock_qualified>=0),

  fact_document jsonb NOT NULL CHECK(jsonb_typeof(fact_document)='object'),
  fact_sha256 text NOT NULL CHECK(fact_sha256 ~ '^[0-9a-f]{64}$'),

  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE(r1d_job_id,r1e_certification_run_id)
);

CREATE OR REPLACE FUNCTION retail.r1f_fact_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1F job facts are immutable';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_fact_guard
BEFORE UPDATE OR DELETE ON retail.r1f_job_facts
FOR EACH ROW EXECUTE FUNCTION retail.r1f_fact_guard();

CREATE INDEX idx_r1f_job_facts_dimension
ON retail.r1f_job_facts(target_id,platform_id,location_fingerprint,completed_at);

-- ---------- IMMUTABLE QUALIFIED OBSERVATION FACTS ---------------------------
CREATE TABLE retail.r1f_observation_facts(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  r1e_result_id uuid NOT NULL REFERENCES retail.r1e_qualification_results(id) ON DELETE RESTRICT,
  r1f_job_fact_id uuid NOT NULL REFERENCES retail.r1f_job_facts(id) ON DELETE RESTRICT,
  target_id uuid NOT NULL REFERENCES retail.search_targets(id) ON DELETE RESTRICT,
  r1a_revision_id uuid NOT NULL REFERENCES retail.search_target_revisions(id) ON DELETE RESTRICT,
  r1a_revision_hash text NOT NULL CHECK(r1a_revision_hash ~ '^[0-9a-f]{64}$'),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  location_fingerprint text NOT NULL,
  product_identity_fingerprint text NOT NULL,
  observation_fingerprint text NOT NULL,
  effective_price numeric,
  availability text,
  quantity_available integer,
  shipping_cost_estimate numeric,
  estimated_tax numeric,
  estimated_total_cost numeric,
  confidence_score numeric NOT NULL CHECK(confidence_score BETWEEN 0 AND 100),
  observed_at timestamptz NOT NULL,
  observation_document jsonb NOT NULL CHECK(jsonb_typeof(observation_document)='object'),
  observation_sha256 text NOT NULL CHECK(observation_sha256 ~ '^[0-9a-f]{64}$'),
  UNIQUE(r1e_result_id)
);

CREATE OR REPLACE FUNCTION retail.r1f_observation_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1F observation facts are immutable';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_observation_guard
BEFORE UPDATE OR DELETE ON retail.r1f_observation_facts
FOR EACH ROW EXECUTE FUNCTION retail.r1f_observation_guard();

CREATE INDEX idx_r1f_observation_price
ON retail.r1f_observation_facts(
  r1a_revision_hash,platform_id,location_fingerprint,observed_at
);

-- ---------- INGEST COMPLETED R1D/R1E TRUTH ----------------------------------
CREATE OR REPLACE FUNCTION retail.r1f_ingest_completed_job(
  p_job_id uuid,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  b retail.r1f_r1e_certification_binding%ROWTYPE;
  rb retail.r1e_r1d_certification_binding%ROWTYPE;
  j retail.r1d_dispatch_jobs%ROWTYPE;
  a retail.r1d_dispatch_attempts%ROWTYPE;
  comp retail.search_job_compilations%ROWTYPE;
  v_attempt_count integer;
  v_collection_run_id uuid;
  v_location jsonb;
  v_location_fp text;
  v_fact_doc jsonb;
  v_fact_id uuid;
  v_capture_total integer;
  v_result_total integer;
  v_qualified integer;
  v_rej_identity integer;
  v_rej_accessory integer;
  v_rej_condition integer;
  v_rej_duplicate integer;
  v_rej_incomplete integer;
  v_min_price numeric;
  v_median_price numeric;
  v_avg_price numeric;
  v_in_stock integer;
  v_cost numeric;
  v_records_requested integer;
  v_records_collected integer;
  q record;
  v_obs_doc jsonb;
BEGIN
  PERFORM retail.r1f_assert_process_run(
    p_process_run_id,
    ARRAY['RETAIL_R1F_INGEST_JOB']
  );

  PERFORM set_config('app.actor_type','worker',true);
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  IF retail.r1f_r1e_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1F ingest blocked: R1E binding stale';
  END IF;

  SELECT * INTO b
  FROM retail.r1f_r1e_certification_binding
  WHERE singleton=true;

  SELECT * INTO rb
  FROM retail.r1e_r1d_certification_binding
  WHERE singleton=true;

  IF rb.r1d_certification_run_id IS NULL THEN
    RAISE EXCEPTION 'R1F requires current R1E→R1D binding';
  END IF;

  SELECT * INTO j
  FROM retail.r1d_dispatch_jobs
  WHERE id=p_job_id
    AND status='succeeded';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1F requires succeeded R1D job';
  END IF;

  SELECT count(*)::int
  INTO v_attempt_count
  FROM retail.r1d_dispatch_attempts
  WHERE job_id=j.id
    AND success=true;

  IF v_attempt_count<>1 THEN
    RAISE EXCEPTION
      'R1F requires exactly one successful R1D attempt per completed job, got %',
      v_attempt_count;
  END IF;

  SELECT * INTO a
  FROM retail.r1d_dispatch_attempts
  WHERE job_id=j.id
    AND success=true;

  v_collection_run_id:=retail.r1e_try_uuid(
    a.metrics_json->>'collection_run_id'
  );

  IF v_collection_run_id IS NULL THEN
    RAISE EXCEPTION 'R1F cannot attribute job without valid collection_run_id';
  END IF;

  IF NOT EXISTS(
    SELECT 1
    FROM retail.collection_runs cr
    WHERE cr.id=v_collection_run_id
      AND cr.platform_id=j.platform_id
  ) THEN
    RAISE EXCEPTION 'R1F collection run missing or platform mismatch';
  END IF;

  SELECT * INTO comp
  FROM retail.search_job_compilations
  WHERE id=j.compilation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1F compilation missing';
  END IF;

  IF comp.platform_id IS DISTINCT FROM j.platform_id THEN
    RAISE EXCEPTION 'R1F job/compilation platform mismatch';
  END IF;

  SELECT count(*)::int
  INTO v_capture_total
  FROM retail.raw_product_captures c
  WHERE c.collection_run_id=v_collection_run_id
    AND c.platform_id=j.platform_id;

  IF v_capture_total=0 THEN
    RAISE EXCEPTION 'R1F collection run has no captures';
  END IF;

  -- Every capture must have exactly one current V2.1 result under the currently
  -- certified R1E ruleset/upstream authority.
  SELECT count(*)::int
  INTO v_result_total
  FROM retail.raw_product_captures c
  WHERE c.collection_run_id=v_collection_run_id
    AND c.platform_id=j.platform_id
    AND (
      SELECT count(*)
      FROM retail.r1e_qualification_results q0
      WHERE q0.raw_capture_id=c.id
        AND q0.ruleset_id=b.r1e_ruleset_id
        AND q0.r1d_certification_run_id=rb.r1d_certification_run_id
        AND q0.engine_version='r1e-v2.1.0'
        AND q0.certification_fixture=false
        AND retail.r1e_result_is_current(q0.id)=true
    )=1;

  IF v_result_total<>v_capture_total THEN
    RAISE EXCEPTION
      'R1F fail-closed: collection qualification incomplete (%/% current)',
      v_result_total,v_capture_total;
  END IF;

  SELECT
    count(*)::int,
    count(*) filter(where q0.decision='QUALIFIED')::int,
    count(*) filter(where q0.decision='REJECTED_IDENTITY')::int,
    count(*) filter(where q0.decision='REJECTED_ACCESSORY')::int,
    count(*) filter(where q0.decision='REJECTED_CONDITION')::int,
    count(*) filter(where q0.decision='REJECTED_DUPLICATE')::int,
    count(*) filter(where q0.decision='REJECTED_INCOMPLETE')::int
  INTO
    v_result_total,v_qualified,v_rej_identity,v_rej_accessory,
    v_rej_condition,v_rej_duplicate,v_rej_incomplete
  FROM retail.r1e_qualification_results q0
  JOIN retail.raw_product_captures c
    ON c.id=q0.raw_capture_id
  WHERE c.collection_run_id=v_collection_run_id
    AND c.platform_id=j.platform_id
    AND q0.ruleset_id=b.r1e_ruleset_id
    AND q0.r1d_certification_run_id=rb.r1d_certification_run_id
    AND q0.engine_version='r1e-v2.1.0'
    AND q0.certification_fixture=false
    AND retail.r1e_result_is_current(q0.id)=true;

  IF v_result_total<>v_capture_total THEN
    RAISE EXCEPTION 'R1F current qualification cardinality drift';
  END IF;

  SELECT
    min(retail.r1f_try_numeric(
      q0.observation_context_json#>>'{offer,effective_price}'
    )),
    percentile_cont(0.5) within group(
      order by retail.r1f_try_numeric(
        q0.observation_context_json#>>'{offer,effective_price}'
      )
    ) filter(
      where retail.r1f_try_numeric(
        q0.observation_context_json#>>'{offer,effective_price}'
      ) is not null
    ),
    avg(retail.r1f_try_numeric(
      q0.observation_context_json#>>'{offer,effective_price}'
    )),
    count(*) filter(
      where lower(COALESCE(
        q0.observation_context_json#>>'{offer,availability}',''
      )) in(
        'in_stock','available',
        'available_for_pickup','available_for_shipping'
      )
    )::int
  INTO v_min_price,v_median_price,v_avg_price,v_in_stock
  FROM retail.r1e_qualification_results q0
  JOIN retail.raw_product_captures c
    ON c.id=q0.raw_capture_id
  WHERE c.collection_run_id=v_collection_run_id
    AND c.platform_id=j.platform_id
    AND q0.ruleset_id=b.r1e_ruleset_id
    AND q0.r1d_certification_run_id=rb.r1d_certification_run_id
    AND q0.engine_version='r1e-v2.1.0'
    AND q0.certification_fixture=false
    AND q0.decision='QUALIFIED'
    AND retail.r1e_result_is_current(q0.id)=true;

  v_cost:=COALESCE(a.actual_cost_usd,j.estimated_cost_usd,0);
  v_records_requested:=retail.r1f_try_integer(
    a.metrics_json->>'records_requested'
  );
  v_records_collected:=retail.r1f_try_integer(
    a.metrics_json->>'records_collected'
  );

  v_location:=COALESCE(
    comp.normalized_job_json->'location',
    '{}'::jsonb
  );
  v_location_fp:=retail.r1f_sha256_jsonb(v_location);

  v_fact_doc:=jsonb_build_object(
    'r1e_certification_run_id',b.r1e_certification_run_id,
    'r1e_package_sha256',b.r1e_package_sha256,
    'ruleset_id',b.r1e_ruleset_id,
    'ruleset_sha256',b.r1e_ruleset_sha256,
    'r1d_certification_run_id',rb.r1d_certification_run_id,
    'r1d_package_sha256',rb.r1d_package_sha256,
    'r1d_job_id',j.id,
    'r1d_attempt_id',a.id,
    'collection_run_id',v_collection_run_id,
    'compilation_id',comp.id,
    'target_id',comp.target_id,
    'r1a_revision_id',comp.r1a_revision_id,
    'r1a_revision_hash',comp.r1a_revision_hash,
    'platform_id',comp.platform_id,
    'collection_source_id',j.collection_source_id,
    'location',v_location,
    'completed_at',a.completed_at,
    'cost_usd',v_cost,
    'cost_basis',COALESCE(a.cost_basis,'estimated'),
    'records_requested',v_records_requested,
    'records_collected',v_records_collected,
    'qualification_counts',jsonb_build_object(
      'total',v_result_total,
      'qualified',v_qualified,
      'rejected_identity',v_rej_identity,
      'rejected_accessory',v_rej_accessory,
      'rejected_condition',v_rej_condition,
      'rejected_duplicate',v_rej_duplicate,
      'rejected_incomplete',v_rej_incomplete
    ),
    'price',jsonb_build_object(
      'min',v_min_price,
      'median',v_median_price,
      'avg',v_avg_price,
      'in_stock_qualified',v_in_stock
    )
  );

  INSERT INTO retail.r1f_job_facts(
    r1d_job_id,r1d_attempt_id,
    r1e_certification_run_id,r1e_package_sha256,
    ruleset_id,ruleset_sha256,
    compilation_id,target_id,r1a_revision_id,r1a_revision_hash,
    platform_id,collection_source_id,
    location_context_json,location_fingerprint,
    location_type,location_code,store_code,postal_code,
    scheduled_for,completed_at,weekday_iso,hour_utc,
    actual_cost_usd,cost_basis,
    records_requested,records_collected,
    observations_total,qualified_observations,
    rejected_identity,rejected_accessory,rejected_condition,
    rejected_duplicate,rejected_incomplete,
    min_qualified_price,median_qualified_price,avg_qualified_price,
    in_stock_qualified,
    fact_document,fact_sha256,
    source_process_run_id,source_correlation_id
  )
  VALUES(
    j.id,a.id,
    b.r1e_certification_run_id,b.r1e_package_sha256,
    b.r1e_ruleset_id,b.r1e_ruleset_sha256,
    comp.id,comp.target_id,comp.r1a_revision_id,comp.r1a_revision_hash,
    comp.platform_id,j.collection_source_id,
    v_location,v_location_fp,
    v_location->>'location_type',
    COALESCE(v_location->>'location_code',v_location->>'code'),
    COALESCE(v_location->>'store_code',v_location->>'store_id'),
    COALESCE(v_location->>'postal_code',v_location->>'zip'),
    j.scheduled_for,a.completed_at,
    extract(isodow from a.completed_at)::int,
    extract(hour from a.completed_at at time zone 'UTC')::int,
    v_cost,COALESCE(a.cost_basis,'estimated'),
    v_records_requested,v_records_collected,
    v_result_total,v_qualified,
    v_rej_identity,v_rej_accessory,v_rej_condition,
    v_rej_duplicate,v_rej_incomplete,
    v_min_price,v_median_price,v_avg_price,v_in_stock,
    v_fact_doc,retail.r1f_sha256_jsonb(v_fact_doc),
    p_process_run_id,p_correlation_id
  )
  ON CONFLICT(r1d_job_id,r1e_certification_run_id) DO NOTHING
  RETURNING id INTO v_fact_id;

  IF v_fact_id IS NULL THEN
    SELECT id INTO v_fact_id
    FROM retail.r1f_job_facts
    WHERE r1d_job_id=j.id
      AND r1e_certification_run_id=b.r1e_certification_run_id;
    RETURN v_fact_id;
  END IF;

  FOR q IN
    SELECT q0.*
    FROM retail.r1e_qualification_results q0
    JOIN retail.raw_product_captures c
      ON c.id=q0.raw_capture_id
    WHERE c.collection_run_id=v_collection_run_id
      AND c.platform_id=j.platform_id
      AND q0.ruleset_id=b.r1e_ruleset_id
      AND q0.r1d_certification_run_id=rb.r1d_certification_run_id
      AND q0.engine_version='r1e-v2.1.0'
      AND q0.certification_fixture=false
      AND q0.decision='QUALIFIED'
      AND retail.r1e_result_is_current(q0.id)=true
  LOOP
    v_obs_doc:=jsonb_build_object(
      'r1e_result_id',q.id,
      'r1f_job_fact_id',v_fact_id,
      'target_id',q.target_id,
      'r1a_revision_id',q.r1a_revision_id,
      'r1a_revision_hash',q.r1a_revision_hash,
      'platform_id',q.platform_id,
      'location_fingerprint',v_location_fp,
      'product_identity_fingerprint',q.product_identity_fingerprint,
      'observation_fingerprint',q.observation_fingerprint,
      'effective_price',retail.r1f_try_numeric(
        q.observation_context_json#>>'{offer,effective_price}'
      ),
      'availability',q.observation_context_json#>>'{offer,availability}',
      'quantity_available',retail.r1f_try_integer(
        q.observation_context_json#>>'{offer,quantity_available}'
      ),
      'shipping_cost_estimate',retail.r1f_try_numeric(
        q.observation_context_json#>>'{offer,shipping_cost_estimate}'
      ),
      'estimated_tax',retail.r1f_try_numeric(
        q.observation_context_json#>>'{offer,estimated_tax}'
      ),
      'estimated_total_cost',retail.r1f_try_numeric(
        q.observation_context_json#>>'{offer,estimated_total_cost}'
      ),
      'confidence_score',q.confidence_score,
      'observed_at',q.qualified_at
    );

    INSERT INTO retail.r1f_observation_facts(
      r1e_result_id,r1f_job_fact_id,target_id,
      r1a_revision_id,r1a_revision_hash,platform_id,
      location_fingerprint,
      product_identity_fingerprint,observation_fingerprint,
      effective_price,availability,quantity_available,
      shipping_cost_estimate,estimated_tax,estimated_total_cost,
      confidence_score,observed_at,
      observation_document,observation_sha256
    )
    VALUES(
      q.id,v_fact_id,q.target_id,
      q.r1a_revision_id,q.r1a_revision_hash,q.platform_id,
      v_location_fp,
      q.product_identity_fingerprint,q.observation_fingerprint,
      retail.r1f_try_numeric(
        q.observation_context_json#>>'{offer,effective_price}'
      ),
      q.observation_context_json#>>'{offer,availability}',
      retail.r1f_try_integer(
        q.observation_context_json#>>'{offer,quantity_available}'
      ),
      retail.r1f_try_numeric(
        q.observation_context_json#>>'{offer,shipping_cost_estimate}'
      ),
      retail.r1f_try_numeric(
        q.observation_context_json#>>'{offer,estimated_tax}'
      ),
      retail.r1f_try_numeric(
        q.observation_context_json#>>'{offer,estimated_total_cost}'
      ),
      q.confidence_score,q.qualified_at,
      v_obs_doc,retail.r1f_sha256_jsonb(v_obs_doc)
    )
    ON CONFLICT(r1e_result_id) DO NOTHING;
  END LOOP;

  RETURN v_fact_id;
END $$;

-- ---------- ROLLING INTELLIGENCE SNAPSHOTS ----------------------------------
CREATE TABLE retail.r1f_intelligence_snapshots(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_id uuid NOT NULL REFERENCES retail.r1f_intelligence_policies(id) ON DELETE RESTRICT,
  policy_sha256 text NOT NULL,
  r1e_certification_run_id uuid NOT NULL REFERENCES retail.r1e_certification_runs(id) ON DELETE RESTRICT,

  target_id uuid NOT NULL REFERENCES retail.search_targets(id) ON DELETE RESTRICT,
  r1a_revision_id uuid NOT NULL REFERENCES retail.search_target_revisions(id) ON DELETE RESTRICT,
  r1a_revision_hash text NOT NULL CHECK(r1a_revision_hash ~ '^[0-9a-f]{64}$'),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  collection_source_id uuid REFERENCES retail.platform_collection_sources(id) ON DELETE RESTRICT,
  location_fingerprint text NOT NULL,
  location_context_json jsonb NOT NULL,

  window_start timestamptz NOT NULL,
  window_end timestamptz NOT NULL,
  sample_jobs integer NOT NULL CHECK(sample_jobs>=0),
  total_observations integer NOT NULL CHECK(total_observations>=0),
  qualified_observations integer NOT NULL CHECK(qualified_observations>=0),
  qualification_rate numeric NOT NULL CHECK(qualification_rate BETWEEN 0 AND 1),

  total_cost_usd numeric NOT NULL CHECK(total_cost_usd>=0),
  cost_per_job_usd numeric,
  cost_per_qualified_usd numeric,

  median_local_price numeric,
  median_reference_price numeric,
  best_local_price numeric,
  relative_bargain_pct numeric,

  available_qualified integer NOT NULL CHECK(available_qualified>=0),
  availability_rate numeric NOT NULL CHECK(availability_rate BETWEEN 0 AND 1),

  qualification_score numeric NOT NULL CHECK(qualification_score BETWEEN 0 AND 100),
  bargain_score numeric NOT NULL CHECK(bargain_score BETWEEN 0 AND 100),
  cost_efficiency_score numeric NOT NULL CHECK(cost_efficiency_score BETWEEN 0 AND 100),
  availability_score numeric NOT NULL CHECK(availability_score BETWEEN 0 AND 100),
  freshness_score numeric NOT NULL CHECK(freshness_score BETWEEN 0 AND 100),
  opportunity_score numeric NOT NULL CHECK(opportunity_score BETWEEN 0 AND 100),

  sample_sufficiency text NOT NULL CHECK(sample_sufficiency IN('INSUFFICIENT','SUFFICIENT')),
  intelligence_document jsonb NOT NULL,
  intelligence_sha256 text NOT NULL CHECK(intelligence_sha256 ~ '^[0-9a-f]{64}$'),

  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE(
    policy_id,r1e_certification_run_id,
    target_id,r1a_revision_hash,platform_id,location_fingerprint,
    window_start,window_end
  )
);

CREATE OR REPLACE FUNCTION retail.r1f_snapshot_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1F intelligence snapshots are immutable';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_snapshot_guard
BEFORE UPDATE OR DELETE ON retail.r1f_intelligence_snapshots
FOR EACH ROW EXECUTE FUNCTION retail.r1f_snapshot_guard();

-- Wilson lower bound guards against over-promoting tiny samples.
CREATE OR REPLACE FUNCTION retail.r1f_wilson_lower_bound(
  p_success integer,
  p_total integer,
  p_z numeric DEFAULT 1.96
)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_total<=0 THEN 0
    ELSE greatest(0,(
      (p_success::numeric/p_total)
      + p_z*p_z/(2*p_total)
      - p_z*sqrt(
          (p_success::numeric/p_total)
          *(1-p_success::numeric/p_total)/p_total
          + p_z*p_z/(4*p_total*p_total)
        )
    )/(1+p_z*p_z/p_total))
  END
$$;


CREATE OR REPLACE FUNCTION retail.r1f_score_document(
  p_metrics jsonb,
  p_policy jsonb
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_total integer:=COALESCE((p_metrics->>'total_observations')::int,0);
  v_qualified integer:=COALESCE((p_metrics->>'qualified_observations')::int,0);
  v_cost_per_qualified numeric:=retail.r1f_try_numeric(
    p_metrics->>'cost_per_qualified_usd'
  );
  v_relative_bargain numeric:=COALESCE(
    retail.r1f_try_numeric(p_metrics->>'relative_bargain_pct'),0
  );
  v_available integer:=COALESCE((p_metrics->>'available_qualified')::int,0);
  v_age_days numeric:=COALESCE(
    retail.r1f_try_numeric(p_metrics->>'freshness_age_days'),999999
  );

  v_qual numeric;
  v_bargain numeric;
  v_cost numeric;
  v_avail numeric;
  v_fresh numeric;
  v_total_score numeric;
BEGIN
  PERFORM retail.r1f_validate_policy(p_policy);

  v_qual:=least(
    100,
    greatest(
      0,
      100*retail.r1f_wilson_lower_bound(
        v_qualified,greatest(v_total,1)
      )
    )
  );

  v_bargain:=least(
    100,
    greatest(
      0,
      100*v_relative_bargain/
        greatest(
          COALESCE(
            (p_policy->>'bargain_pct_for_full_score')::numeric,
            0.30
          ),
          0.000001
        )
    )
  );

  v_cost:=CASE
    WHEN v_cost_per_qualified IS NULL THEN 0
    ELSE least(
      100,
      greatest(
        0,
        100*(
          1-v_cost_per_qualified/
            greatest(
              COALESCE(
                (p_policy->>'max_cost_per_qualified_usd')::numeric,
                1
              ),
              0.000001
            )
        )
      )
    )
  END;

  v_avail:=CASE
    WHEN v_qualified<=0 THEN 0
    ELSE least(
      100,
      greatest(
        0,
        100*v_available::numeric/v_qualified
      )
    )
  END;

  v_fresh:=least(
    100,
    greatest(
      0,
      100*(
        1-v_age_days/
          greatest(
            COALESCE(
              (p_policy->>'freshness_days_for_zero')::numeric,
              7
            ),
            0.000001
          )
      )
    )
  );

  v_total_score:=round(
    v_qual*
      (p_policy#>>'{score_weights,qualification_yield}')::numeric+
    v_bargain*
      (p_policy#>>'{score_weights,relative_bargain}')::numeric+
    v_cost*
      (p_policy#>>'{score_weights,cost_efficiency}')::numeric+
    v_avail*
      (p_policy#>>'{score_weights,availability}')::numeric+
    v_fresh*
      (p_policy#>>'{score_weights,freshness}')::numeric,
    4
  );

  RETURN jsonb_build_object(
    'qualification_score',round(v_qual,4),
    'bargain_score',round(v_bargain,4),
    'cost_efficiency_score',round(v_cost,4),
    'availability_score',round(v_avail,4),
    'freshness_score',round(v_fresh,4),
    'opportunity_score',v_total_score
  );
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_build_intelligence(
  p_policy_id uuid,
  p_window_end timestamptz,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  p retail.r1f_intelligence_policies%ROWTYPE;
  b retail.r1f_r1e_certification_binding%ROWTYPE;
  r record;
  v_start timestamptz;
  v_metrics jsonb;
  v_scores jsonb;
  v_doc jsonb;
  v_count integer:=0;
BEGIN
  PERFORM retail.r1f_assert_process_run(
    p_process_run_id,
    ARRAY['RETAIL_R1F_BUILD_INTELLIGENCE']
  );

  PERFORM set_config('app.actor_type','worker',true);
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  IF retail.r1f_r1e_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1F intelligence blocked: R1E binding stale';
  END IF;

  SELECT * INTO p
  FROM retail.r1f_intelligence_policies
  WHERE id=p_policy_id
    AND certification_status='certified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Certified R1F policy required';
  END IF;

  PERFORM retail.r1f_validate_policy(p.policy_json);

  SELECT * INTO b
  FROM retail.r1f_r1e_certification_binding
  WHERE singleton=true;

  v_start:=p_window_end-
    make_interval(days=>(p.policy_json->>'lookback_days')::int);

  FOR r IN
    WITH fact_agg AS (
      SELECT
        f.target_id,
        f.r1a_revision_id,
        f.r1a_revision_hash,
        f.platform_id,
        f.collection_source_id,
        f.location_fingerprint,
        (array_agg(
          f.location_context_json
          ORDER BY f.completed_at DESC,f.id
        ))[1] location_context_json,
        count(*)::int sample_jobs,
        sum(f.observations_total)::int total_observations,
        sum(f.qualified_observations)::int qualified_observations,
        sum(f.actual_cost_usd) total_cost_usd,
        avg(f.actual_cost_usd) cost_per_job_usd,
        CASE
          WHEN sum(f.qualified_observations)>0
          THEN sum(f.actual_cost_usd)/sum(f.qualified_observations)
        END cost_per_qualified_usd,
        max(f.completed_at) last_completed_at
      FROM retail.r1f_job_facts f
      WHERE f.r1e_certification_run_id=b.r1e_certification_run_id
        AND f.completed_at>=v_start
        AND f.completed_at<=p_window_end
        AND f.fact_sha256=retail.r1f_sha256_jsonb(f.fact_document)
      GROUP BY
        f.target_id,f.r1a_revision_id,f.r1a_revision_hash,f.platform_id,
        f.collection_source_id,f.location_fingerprint
    ),
    observation_relative AS (
      SELECT
        o.target_id,
        o.r1a_revision_id,
        o.r1a_revision_hash,
        o.platform_id,
        f.collection_source_id,
        o.location_fingerprint,
        o.effective_price,
        o.availability,
        ref.reference_price,
        CASE
          WHEN o.effective_price IS NULL
            OR ref.reference_price IS NULL
            OR ref.reference_price<=0
          THEN NULL
          ELSE greatest(
            0,
            (ref.reference_price-o.effective_price)/ref.reference_price
          )
        END relative_bargain_pct
      FROM retail.r1f_observation_facts o
      JOIN retail.r1f_job_facts f
        ON f.id=o.r1f_job_fact_id
      JOIN LATERAL (
        SELECT percentile_cont(0.5) within group(
          order by o2.effective_price
        ) reference_price
        FROM retail.r1f_observation_facts o2
        JOIN retail.r1f_job_facts f2
          ON f2.id=o2.r1f_job_fact_id
        WHERE o2.r1a_revision_hash=o.r1a_revision_hash
          AND o2.effective_price IS NOT NULL
          AND f2.r1e_certification_run_id=
              b.r1e_certification_run_id
          AND f2.completed_at>=v_start
          AND f2.completed_at<=p_window_end
      ) ref ON true
      WHERE f.r1e_certification_run_id=b.r1e_certification_run_id
        AND f.completed_at>=v_start
        AND f.completed_at<=p_window_end
        AND o.observation_sha256=
            retail.r1f_sha256_jsonb(o.observation_document)
    ),
    obs_agg AS (
      SELECT
        target_id,
        r1a_revision_id,
        r1a_revision_hash,
        platform_id,
        collection_source_id,
        location_fingerprint,
        min(effective_price) best_local_price,
        percentile_cont(0.5) within group(
          order by effective_price
        ) filter(where effective_price is not null) median_local_price,
        percentile_cont(0.5) within group(
          order by reference_price
        ) filter(where reference_price is not null) median_reference_price,
        percentile_cont(0.5) within group(
          order by relative_bargain_pct
        ) filter(where relative_bargain_pct is not null)
          median_relative_bargain_pct,
        count(*) filter(
          where lower(COALESCE(availability,'')) in(
            'in_stock','available',
            'available_for_pickup','available_for_shipping'
          )
        )::int available_qualified
      FROM observation_relative
      GROUP BY
        target_id,r1a_revision_id,r1a_revision_hash,platform_id,
        collection_source_id,location_fingerprint
    )
    SELECT
      fa.*,
      oa.best_local_price,
      oa.median_local_price,
      oa.median_reference_price,
      COALESCE(oa.median_relative_bargain_pct,0)
        median_relative_bargain_pct,
      COALESCE(oa.available_qualified,0) available_qualified
    FROM fact_agg fa
    LEFT JOIN obs_agg oa
      ON oa.target_id=fa.target_id
     AND oa.r1a_revision_hash=fa.r1a_revision_hash
     AND oa.platform_id=fa.platform_id
     AND oa.collection_source_id IS NOT DISTINCT FROM
         fa.collection_source_id
     AND oa.location_fingerprint=fa.location_fingerprint
  LOOP
    v_metrics:=jsonb_build_object(
      'total_observations',r.total_observations,
      'qualified_observations',r.qualified_observations,
      'cost_per_qualified_usd',r.cost_per_qualified_usd,
      'relative_bargain_pct',r.median_relative_bargain_pct,
      'available_qualified',r.available_qualified,
      'freshness_age_days',
        greatest(
          0,
          extract(epoch from (p_window_end-r.last_completed_at))/86400
        )
    );

    v_scores:=retail.r1f_score_document(
      v_metrics,p.policy_json
    );

    v_doc:=jsonb_build_object(
      'policy_id',p.id,
      'policy_sha256',p.policy_sha256,
      'r1e_certification_run_id',b.r1e_certification_run_id,
      'target_id',r.target_id,
      'r1a_revision_id',r.r1a_revision_id,
      'r1a_revision_hash',r.r1a_revision_hash,
      'platform_id',r.platform_id,
      'collection_source_id',r.collection_source_id,
      'location_fingerprint',r.location_fingerprint,
      'location',r.location_context_json,
      'window_start',v_start,
      'window_end',p_window_end,
      'sample_jobs',r.sample_jobs,
      'metrics',v_metrics,
      'total_cost_usd',r.total_cost_usd,
      'cost_per_job_usd',r.cost_per_job_usd,
      'best_local_price',r.best_local_price,
      'median_local_price',r.median_local_price,
      'median_reference_price',r.median_reference_price,
      'scores',v_scores
    );

    INSERT INTO retail.r1f_intelligence_snapshots(
      policy_id,policy_sha256,r1e_certification_run_id,
      target_id,r1a_revision_id,r1a_revision_hash,
      platform_id,collection_source_id,
      location_fingerprint,location_context_json,
      window_start,window_end,
      sample_jobs,total_observations,qualified_observations,
      qualification_rate,
      total_cost_usd,cost_per_job_usd,cost_per_qualified_usd,
      median_local_price,median_reference_price,best_local_price,
      relative_bargain_pct,
      available_qualified,availability_rate,
      qualification_score,bargain_score,cost_efficiency_score,
      availability_score,freshness_score,opportunity_score,
      sample_sufficiency,
      intelligence_document,intelligence_sha256,
      source_process_run_id,source_correlation_id
    )
    VALUES(
      p.id,p.policy_sha256,b.r1e_certification_run_id,
      r.target_id,r.r1a_revision_id,r.r1a_revision_hash,
      r.platform_id,r.collection_source_id,
      r.location_fingerprint,r.location_context_json,
      v_start,p_window_end,
      r.sample_jobs,r.total_observations,r.qualified_observations,
      CASE
        WHEN r.total_observations=0 THEN 0
        ELSE r.qualified_observations::numeric/r.total_observations
      END,
      r.total_cost_usd,r.cost_per_job_usd,r.cost_per_qualified_usd,
      r.median_local_price,r.median_reference_price,r.best_local_price,
      r.median_relative_bargain_pct,
      r.available_qualified,
      CASE
        WHEN r.qualified_observations=0 THEN 0
        ELSE least(
          1,
          r.available_qualified::numeric/r.qualified_observations
        )
      END,
      (v_scores->>'qualification_score')::numeric,
      (v_scores->>'bargain_score')::numeric,
      (v_scores->>'cost_efficiency_score')::numeric,
      (v_scores->>'availability_score')::numeric,
      (v_scores->>'freshness_score')::numeric,
      (v_scores->>'opportunity_score')::numeric,
      CASE
        WHEN r.sample_jobs >=
          (p.policy_json->>'minimum_sample_jobs')::int
        THEN 'SUFFICIENT'
        ELSE 'INSUFFICIENT'
      END,
      v_doc,retail.r1f_sha256_jsonb(v_doc),
      p_process_run_id,p_correlation_id
    )
    ON CONFLICT DO NOTHING;

    v_count:=v_count+1;
  END LOOP;

  RETURN v_count;
END $$;

-- ---------- GOVERNED RECOMMENDATIONS ----------------------------------------
CREATE TABLE retail.r1f_search_recommendations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recommendation_key text NOT NULL UNIQUE,
  policy_id uuid NOT NULL REFERENCES retail.r1f_intelligence_policies(id) ON DELETE RESTRICT,
  policy_sha256 text NOT NULL,
  intelligence_snapshot_id uuid
    REFERENCES retail.r1f_intelligence_snapshots(id) ON DELETE RESTRICT,
  r1e_certification_run_id uuid NOT NULL REFERENCES retail.r1e_certification_runs(id) ON DELETE RESTRICT,

  target_id uuid NOT NULL REFERENCES retail.search_targets(id) ON DELETE RESTRICT,
  r1a_revision_id uuid NOT NULL REFERENCES retail.search_target_revisions(id) ON DELETE RESTRICT,
  r1a_revision_hash text NOT NULL CHECK(r1a_revision_hash ~ '^[0-9a-f]{64}$'),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  compilation_id uuid NOT NULL REFERENCES retail.search_job_compilations(id) ON DELETE RESTRICT,
  location_fingerprint text NOT NULL,

  recommendation_type text NOT NULL CHECK(recommendation_type IN(
    'MAINTAIN',
    'INCREASE_FREQUENCY',
    'DECREASE_FREQUENCY',
    'EXPAND_GEO_CHILDREN',
    'EXPLORATION_SAMPLE'
  )),
  recommendation_priority integer NOT NULL CHECK(recommendation_priority BETWEEN 1 AND 1000),
  recommended_interval_seconds integer,
  recommended_geo_fanout integer,
  exploration boolean NOT NULL DEFAULT false,
  expires_at timestamptz NOT NULL,

  recommendation_document jsonb NOT NULL CHECK(jsonb_typeof(recommendation_document)='object'),
  recommendation_sha256 text NOT NULL CHECK(recommendation_sha256 ~ '^[0-9a-f]{64}$'),

  status text NOT NULL DEFAULT 'PROPOSED'
    CHECK(status IN('PROPOSED','ACCEPTED','REJECTED','EXPIRED','SUPERSEDED')),
  decision_by text,
  decision_at timestamptz,
  decision_reason text,

  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1f_recommendation_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1F recommendations cannot be deleted';
  END IF;

  IF (to_jsonb(NEW)-ARRAY[
        'status','decision_by','decision_at','decision_reason'
      ])
     IS DISTINCT FROM
     (to_jsonb(OLD)-ARRAY[
        'status','decision_by','decision_at','decision_reason'
      ]) THEN
    RAISE EXCEPTION 'R1F recommendation authority fields immutable';
  END IF;

  IF OLD.status<>'PROPOSED'
     AND NEW.status<>OLD.status THEN
    RAISE EXCEPTION 'Terminal R1F recommendation decision cannot be changed';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_recommendation_guard
BEFORE UPDATE OR DELETE ON retail.r1f_search_recommendations
FOR EACH ROW EXECUTE FUNCTION retail.r1f_recommendation_guard();


CREATE OR REPLACE FUNCTION retail.r1f_recommendation_decision(
  p_snapshot jsonb,
  p_policy jsonb
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_score numeric:=COALESCE(
    retail.r1f_try_numeric(p_snapshot->>'opportunity_score'),0
  );
  v_sample text:=COALESCE(
    p_snapshot->>'sample_sufficiency','INSUFFICIENT'
  );
  v_location_type text:=COALESCE(
    p_snapshot#>>'{location,location_type}',
    'national'
  );
  v_type text;
  v_priority integer;
  v_interval integer;
  v_fanout integer;
  v_exploration boolean:=false;
BEGIN
  PERFORM retail.r1f_validate_policy(p_policy);

  IF v_sample='INSUFFICIENT' THEN
    v_type:='EXPLORATION_SAMPLE';
    v_exploration:=true;
    v_priority:=500;
    v_interval:=COALESCE(
      (p_policy->>'exploration_interval_seconds')::int,
      86400
    );
  ELSIF v_score>=COALESCE(
      (p_policy->>'increase_frequency_score')::numeric,75
    ) THEN
    IF v_location_type IN(
      'national','region','state','metro','postal_code'
    ) THEN
      v_type:='EXPAND_GEO_CHILDREN';
      v_fanout:=COALESCE(
        (p_policy->>'max_geo_fanout')::int,10
      );
    ELSE
      v_type:='INCREASE_FREQUENCY';
      v_interval:=COALESCE(
        (p_policy->>'high_opportunity_interval_seconds')::int,
        3600
      );
    END IF;
    v_priority:=greatest(
      1,1000-round(v_score*9)::int
    );
  ELSIF v_score<=COALESCE(
      (p_policy->>'decrease_frequency_score')::numeric,25
    ) THEN
    v_type:='DECREASE_FREQUENCY';
    v_interval:=COALESCE(
      (p_policy->>'low_opportunity_interval_seconds')::int,
      604800
    );
    v_priority:=900;
  ELSE
    v_type:='MAINTAIN';
    v_priority:=700;
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'recommendation_type',v_type,
    'recommendation_priority',v_priority,
    'recommended_interval_seconds',v_interval,
    'recommended_geo_fanout',v_fanout,
    'exploration',v_exploration
  ));
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_generate_recommendations(
  p_policy_id uuid,
  p_window_end timestamptz,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  p retail.r1f_intelligence_policies%ROWTYPE;
  s retail.r1f_intelligence_snapshots%ROWTYPE;
  ec record;
  b retail.r1f_r1e_certification_binding%ROWTYPE;
  v_decision jsonb;
  v_doc jsonb;
  v_key text;
  v_count integer:=0;
  v_compilation uuid;
  v_compilation_count integer;
BEGIN
  PERFORM retail.r1f_assert_process_run(
    p_process_run_id,
    ARRAY['RETAIL_R1F_RECOMMEND']
  );

  PERFORM set_config('app.actor_type','worker',true);
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  IF retail.r1f_r1e_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1F recommendations blocked: R1E binding stale';
  END IF;

  SELECT * INTO p
  FROM retail.r1f_intelligence_policies
  WHERE id=p_policy_id
    AND certification_status='certified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Certified R1F policy required';
  END IF;

  PERFORM retail.r1f_validate_policy(p.policy_json);

  SELECT * INTO b
  FROM retail.r1f_r1e_certification_binding
  WHERE singleton=true;

  FOR s IN
    SELECT *
    FROM retail.r1f_intelligence_snapshots
    WHERE policy_id=p.id
      AND window_end=p_window_end
    ORDER BY opportunity_score DESC,id
  LOOP
    -- Recommendation authority can bind only an already-current compiled route.
    SELECT
      count(*)::int,
      (array_agg(ec.id ORDER BY ec.id::text))[1]
    INTO v_compilation_count,v_compilation
    FROM retail.effective_compiled_search_jobs ec
    WHERE ec.target_id=s.target_id
      AND ec.r1a_revision_id=r.r1a_revision_id
      AND ec.r1a_revision_hash=r.r1a_revision_hash
      AND ec.platform_id=s.platform_id
      AND retail.r1f_sha256_jsonb(
        COALESCE(ec.normalized_job_json->'location','{}'::jsonb)
      )=s.location_fingerprint;

    IF v_compilation_count<>1 THEN
      -- Missing or contradictory current route authority cannot be recommended.
      CONTINUE;
    END IF;

    v_decision:=retail.r1f_recommendation_decision(
      jsonb_build_object(
        'opportunity_score',s.opportunity_score,
        'sample_sufficiency',s.sample_sufficiency,
        'location',s.location_context_json
      ),
      p.policy_json
    );

    v_doc:=jsonb_build_object(
      'policy_id',p.id,
      'policy_sha256',p.policy_sha256,
      'intelligence_snapshot_id',s.id,
      'r1e_certification_run_id',s.r1e_certification_run_id,
      'target_id',s.target_id,
      'r1a_revision_id',s.r1a_revision_id,
      'r1a_revision_hash',s.r1a_revision_hash,
      'platform_id',s.platform_id,
      'compilation_id',v_compilation,
      'location_fingerprint',s.location_fingerprint,
      'location',s.location_context_json,
      'opportunity_score',s.opportunity_score,
      'sample_sufficiency',s.sample_sufficiency,
      'recommendation',v_decision,
      'expires_at',p_window_end+
        make_interval(days=>COALESCE(
          (p.policy_json->>'recommendation_ttl_days')::int,7
        ))
    );

    v_key:=retail.r1f_sha256_jsonb(jsonb_build_object(
      'policy_id',p.id,
      'snapshot_id',s.id,
      'compilation_id',v_compilation,
      'recommendation_type',v_decision->>'recommendation_type'
    ));

    INSERT INTO retail.r1f_search_recommendations(
      recommendation_key,
      policy_id,policy_sha256,intelligence_snapshot_id,
      r1e_certification_run_id,
      target_id,r1a_revision_id,r1a_revision_hash,
      platform_id,compilation_id,location_fingerprint,
      recommendation_type,recommendation_priority,
      recommended_interval_seconds,recommended_geo_fanout,
      exploration,expires_at,
      recommendation_document,recommendation_sha256,
      source_process_run_id,source_correlation_id
    )
    VALUES(
      v_key,
      p.id,p.policy_sha256,s.id,s.r1e_certification_run_id,
      s.target_id,s.r1a_revision_id,s.r1a_revision_hash,
      s.platform_id,v_compilation,s.location_fingerprint,
      v_decision->>'recommendation_type',
      (v_decision->>'recommendation_priority')::int,
      retail.r1f_try_integer(
        v_decision->>'recommended_interval_seconds'
      ),
      retail.r1f_try_integer(
        v_decision->>'recommended_geo_fanout'
      ),
      COALESCE((v_decision->>'exploration')::boolean,false),
      (v_doc->>'expires_at')::timestamptz,
      v_doc,retail.r1f_sha256_jsonb(v_doc),
      p_process_run_id,p_correlation_id
    )
    ON CONFLICT(recommendation_key) DO NOTHING;

    v_count:=v_count+1;
  END LOOP;

  -- Nationwide exploration: authorized current R1C routes that have not
  -- produced a current R1F fact inside the lookback window still receive a
  -- bounded EXPLORATION_SAMPLE recommendation. This is how TCDS can
  -- progressively search the U.S. without brute-forcing every store every run.
  FOR ec IN
    SELECT
      c.id compilation_id,
      c.target_id,
      c.r1a_revision_id,
      c.r1a_revision_hash,
      c.platform_id,
      COALESCE(c.normalized_job_json->'location','{}'::jsonb) location_context
    FROM retail.effective_compiled_search_jobs c
    WHERE NOT EXISTS(
      SELECT 1
      FROM retail.r1f_job_facts f
      WHERE f.compilation_id=c.id
        AND f.r1e_certification_run_id=b.r1e_certification_run_id
        AND f.completed_at>=
          p_window_end-make_interval(
            days=>(p.policy_json->>'lookback_days')::int
          )
        AND f.completed_at<=p_window_end
    )
    ORDER BY hashtextextended(
      c.id::text||':'||(p_window_end at time zone 'UTC')::date::text,
      0
    )
    LIMIT (p.policy_json->>'max_exploration_recommendations_per_run')::int
  LOOP
    v_decision:=jsonb_build_object(
      'recommendation_type','EXPLORATION_SAMPLE',
      'recommendation_priority',600,
      'recommended_interval_seconds',
        COALESCE(
          (p.policy_json->>'exploration_interval_seconds')::int,
          86400
        ),
      'exploration',true
    );

    v_doc:=jsonb_build_object(
      'policy_id',p.id,
      'policy_sha256',p.policy_sha256,
      'intelligence_snapshot_id',NULL,
      'r1e_certification_run_id',b.r1e_certification_run_id,
      'target_id',ec.target_id,
      'r1a_revision_id',ec.r1a_revision_id,
      'r1a_revision_hash',ec.r1a_revision_hash,
      'platform_id',ec.platform_id,
      'compilation_id',ec.compilation_id,
      'location_fingerprint',
        retail.r1f_sha256_jsonb(ec.location_context),
      'location',ec.location_context,
      'opportunity_score',NULL,
      'sample_sufficiency','INSUFFICIENT',
      'recommendation',v_decision,
      'recommendation_basis','UNSAMPLED_AUTHORIZED_ROUTE',
      'expires_at',p_window_end+
        make_interval(days=>COALESCE(
          (p.policy_json->>'recommendation_ttl_days')::int,
          7
        ))
    );

    v_key:=retail.r1f_sha256_jsonb(jsonb_build_object(
      'policy_id',p.id,
      'window_end',p_window_end,
      'compilation_id',ec.compilation_id,
      'recommendation_type','EXPLORATION_SAMPLE'
    ));

    INSERT INTO retail.r1f_search_recommendations(
      recommendation_key,
      policy_id,policy_sha256,intelligence_snapshot_id,
      r1e_certification_run_id,
      target_id,r1a_revision_id,r1a_revision_hash,
      platform_id,compilation_id,location_fingerprint,
      recommendation_type,recommendation_priority,
      recommended_interval_seconds,recommended_geo_fanout,
      exploration,expires_at,
      recommendation_document,recommendation_sha256,
      source_process_run_id,source_correlation_id
    )
    VALUES(
      v_key,
      p.id,p.policy_sha256,NULL,
      b.r1e_certification_run_id,
      ec.target_id,ec.r1a_revision_id,ec.r1a_revision_hash,
      ec.platform_id,ec.compilation_id,
      retail.r1f_sha256_jsonb(ec.location_context),
      'EXPLORATION_SAMPLE',600,
      COALESCE(
        (p.policy_json->>'exploration_interval_seconds')::int,
        86400
      ),
      NULL,true,
      (v_doc->>'expires_at')::timestamptz,
      v_doc,retail.r1f_sha256_jsonb(v_doc),
      p_process_run_id,p_correlation_id
    )
    ON CONFLICT(recommendation_key) DO NOTHING;

    v_count:=v_count+1;
  END LOOP;

  RETURN v_count;
END $$;

-- R1D can read proposed recommendations, but acceptance remains a separate
-- governed decision. R1F has no UPDATE rights on R1D policy/schedule tables.
CREATE OR REPLACE VIEW retail.r1f_proposed_search_recommendations AS
SELECT r.*
FROM retail.r1f_search_recommendations r
JOIN retail.r1f_intelligence_policies p
  ON p.id=r.policy_id
WHERE r.status='PROPOSED'
  AND r.expires_at>now()
  AND p.certification_status='certified'
  AND p.policy_sha256=r.policy_sha256
  AND p.policy_sha256=retail.r1f_sha256_jsonb(p.policy_json)
  AND retail.r1f_r1e_binding_is_current()=true
  AND r.recommendation_sha256=
      retail.r1f_sha256_jsonb(r.recommendation_document);

-- ---------- CERTIFICATION POLICY / QA ---------------------------------------
CREATE TABLE retail.r1f_qa_fixtures(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fixture_code text NOT NULL UNIQUE,
  fixture_class text NOT NULL CHECK(fixture_class IN(
    'high_opportunity','low_opportunity','insufficient_sample',
    'high_cost','strong_bargain','weak_availability','exploration'
  )),
  input_json jsonb NOT NULL CHECK(jsonb_typeof(input_json)='object'),
  expected_json jsonb NOT NULL CHECK(jsonb_typeof(expected_json)='object'),
  fixture_sha256 text NOT NULL CHECK(fixture_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1f_fixture_document(
  p_row retail.r1f_qa_fixtures
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT
AS $$
  SELECT jsonb_build_object(
    'fixture_code',p_row.fixture_code,
    'fixture_class',p_row.fixture_class,
    'input_json',p_row.input_json,
    'expected_json',p_row.expected_json
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1f_prepare_fixture()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.fixture_sha256:=retail.r1f_sha256_jsonb(
    retail.r1f_fixture_document(NEW)
  );
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_prepare_fixture
BEFORE INSERT OR UPDATE ON retail.r1f_qa_fixtures
FOR EACH ROW EXECUTE FUNCTION retail.r1f_prepare_fixture();

CREATE OR REPLACE FUNCTION retail.r1f_fixture_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1F QA fixtures cannot be deleted';
  END IF;
  IF OLD.active=true THEN
    IF (to_jsonb(NEW)-ARRAY['active'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['active']) THEN
      RAISE EXCEPTION 'Active R1F QA fixture immutable';
    END IF;
  ELSIF NEW.active<>OLD.active THEN
    RAISE EXCEPTION 'Inactive R1F fixture cannot be reactivated';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_fixture_guard
BEFORE UPDATE OR DELETE ON retail.r1f_qa_fixtures
FOR EACH ROW EXECUTE FUNCTION retail.r1f_fixture_guard();


CREATE TABLE retail.r1f_certification_policies(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_code text NOT NULL,
  policy_version text NOT NULL,
  policy_json jsonb NOT NULL CHECK(jsonb_typeof(policy_json)='object'),
  policy_sha256 text NOT NULL CHECK(policy_sha256 ~ '^[0-9a-f]{64}$'),
  certification_status text NOT NULL DEFAULT 'draft'
    CHECK(certification_status IN('draft','certified','suspended','retired')),
  created_by text NOT NULL,
  certified_by text,
  certification_process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  certification_correlation_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  certified_at timestamptz,
  UNIQUE(policy_code,policy_version)
);

CREATE UNIQUE INDEX uq_r1f_one_certified_cert_policy
ON retail.r1f_certification_policies(policy_code)
WHERE certification_status='certified';

CREATE OR REPLACE FUNCTION retail.r1f_prepare_cert_policy()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.policy_sha256:=retail.r1f_sha256_jsonb(NEW.policy_json);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_prepare_cert_policy
BEFORE INSERT OR UPDATE ON retail.r1f_certification_policies
FOR EACH ROW EXECUTE FUNCTION retail.r1f_prepare_cert_policy();

CREATE OR REPLACE FUNCTION retail.r1f_cert_policy_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1F certification policies cannot be deleted';
  END IF;

  IF OLD.certification_status='certified' THEN
    IF (to_jsonb(NEW)-ARRAY['certification_status'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['certification_status']) THEN
      RAISE EXCEPTION 'Certified R1F certification policy immutable';
    END IF;
    IF NEW.certification_status NOT IN('certified','suspended','retired') THEN
      RAISE EXCEPTION 'Invalid R1F certification policy transition';
    END IF;
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_cert_policy_guard
BEFORE UPDATE OR DELETE ON retail.r1f_certification_policies
FOR EACH ROW EXECUTE FUNCTION retail.r1f_cert_policy_guard();

CREATE OR REPLACE FUNCTION retail.r1f_validate_certification_policy(
  p_policy jsonb
)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_class text;
  v_required_classes constant text[]:=ARRAY[
    'high_opportunity','low_opportunity','insufficient_sample',
    'high_cost','strong_bargain','weak_availability','exploration'
  ];
BEGIN
  IF p_policy IS NULL OR jsonb_typeof(p_policy)<>'object' THEN
    RAISE EXCEPTION 'R1F certification policy must be object';
  END IF;

  IF COALESCE((p_policy->>'minimum_total_fixtures')::int,0)<500
     OR COALESCE((p_policy->>'minimum_score_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_recommendation_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_replay_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_fact_hash_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_recommendation_hash_coverage')::numeric,-1)<100 THEN
    RAISE EXCEPTION 'R1F certification policy weaker than Green Tier 1 floor';
  END IF;

  IF jsonb_typeof(COALESCE(p_policy->'class_minimums','{}'::jsonb))<>'object' THEN
    RAISE EXCEPTION 'R1F class_minimums must be object';
  END IF;

  FOREACH v_class IN ARRAY v_required_classes
  LOOP
    IF COALESCE((p_policy#>>ARRAY['class_minimums',v_class])::int,0)<50 THEN
      RAISE EXCEPTION 'R1F class % requires at least 50 fixtures',v_class;
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_certify_certification_policy(
  p_policy_id uuid,
  p_process_run_id uuid,
  p_correlation_id text,
  p_certifier text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  p retail.r1f_certification_policies%ROWTYPE;
BEGIN
  PERFORM retail.r1f_assert_process_run(
    p_process_run_id,
    ARRAY['RETAIL_R1F_POLICY_REGISTER']
  );

  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id',p_certifier,true);
  PERFORM set_config('app.actor_name',p_certifier,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  SELECT * INTO p
  FROM retail.r1f_certification_policies
  WHERE id=p_policy_id
  FOR UPDATE;

  IF NOT FOUND OR p.certification_status<>'draft' THEN
    RAISE EXCEPTION 'R1F certification policy missing/not eligible';
  END IF;

  PERFORM retail.r1f_validate_certification_policy(p.policy_json);

  UPDATE retail.r1f_certification_policies
  SET certification_status='suspended'
  WHERE policy_code=p.policy_code
    AND id<>p.id
    AND certification_status='certified';

  UPDATE retail.r1f_certification_policies
  SET certification_status='certified',
      certified_by=p_certifier,
      certification_process_run_id=p_process_run_id,
      certification_correlation_id=p_correlation_id,
      certified_at=now()
  WHERE id=p.id;
END $$;

CREATE TABLE retail.r1f_certification_runs(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  certification_version text NOT NULL,
  r1e_certification_run_id uuid NOT NULL REFERENCES retail.r1e_certification_runs(id) ON DELETE RESTRICT,
  r1e_package_sha256 text NOT NULL,
  r1f_package_sha256 text NOT NULL,
  policy_id uuid NOT NULL REFERENCES retail.r1f_intelligence_policies(id) ON DELETE RESTRICT,
  policy_sha256 text NOT NULL,
  certification_policy_id uuid NOT NULL REFERENCES retail.r1f_certification_policies(id) ON DELETE RESTRICT,
  certification_policy_sha256 text NOT NULL,
  passive_results jsonb NOT NULL,
  active_results jsonb NOT NULL,
  replay_results jsonb NOT NULL,
  evidence_manifest jsonb NOT NULL,
  evidence_manifest_text text NOT NULL,
  evidence_manifest_sha256 text NOT NULL,
  total_gates integer NOT NULL,
  passed_gates integer NOT NULL,
  failed_gates integer NOT NULL,
  certification_status text NOT NULL CHECK(certification_status IN('CERTIFIED','FAILED')),
  certified_by text NOT NULL,
  completed_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1f_certification_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1F certification records are append-only';
  END IF;

  IF NEW.evidence_manifest_sha256<>
     retail.r1f_sha256_text(NEW.evidence_manifest_text) THEN
    RAISE EXCEPTION 'R1F certification evidence SHA mismatch';
  END IF;

  IF NEW.evidence_manifest IS DISTINCT FROM NEW.evidence_manifest_text::jsonb THEN
    RAISE EXCEPTION 'R1F certification evidence JSON/text mismatch';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_certification_guard
BEFORE INSERT OR UPDATE OR DELETE ON retail.r1f_certification_runs
FOR EACH ROW EXECUTE FUNCTION retail.r1f_certification_guard();

CREATE OR REPLACE FUNCTION retail.r1f_certification_insert_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.certification_version<>'r1f-v1.0.0' THEN
    RAISE EXCEPTION 'Unsupported R1F certification version %',
      NEW.certification_version;
  END IF;

  IF NEW.r1f_package_sha256 !~ '^[0-9a-f]{64}$'
     OR NEW.r1e_package_sha256 !~ '^[0-9a-f]{64}$'
     OR NEW.evidence_manifest_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R1F certification SHA format invalid';
  END IF;

  IF NEW.certification_status='CERTIFIED' THEN
    IF NEW.failed_gates<>0
       OR NEW.passed_gates<>NEW.total_gates THEN
      RAISE EXCEPTION
        'R1F CERTIFIED requires every gate to pass';
    END IF;

    IF retail.r1f_r1e_binding_is_current() IS NOT TRUE THEN
      RAISE EXCEPTION 'R1F certification requires current R1E binding';
    END IF;

    IF NOT EXISTS(
      SELECT 1
      FROM retail.r1f_intelligence_policies p
      WHERE p.id=NEW.policy_id
        AND p.certification_status='certified'
        AND p.policy_sha256=NEW.policy_sha256
        AND p.policy_sha256=retail.r1f_sha256_jsonb(p.policy_json)
    ) THEN
      RAISE EXCEPTION 'R1F certification intelligence policy invalid';
    END IF;

    IF NOT EXISTS(
      SELECT 1
      FROM retail.r1f_certification_policies cp
      WHERE cp.id=NEW.certification_policy_id
        AND cp.certification_status='certified'
        AND cp.policy_sha256=NEW.certification_policy_sha256
        AND cp.policy_sha256=retail.r1f_sha256_jsonb(cp.policy_json)
    ) THEN
      RAISE EXCEPTION 'R1F Green Tier certification policy invalid';
    END IF;

    IF NOT EXISTS(
      SELECT 1
      FROM retail.r1f_r1e_certification_binding b
      WHERE b.singleton=true
        AND b.r1e_certification_run_id=NEW.r1e_certification_run_id
        AND b.r1e_package_sha256=NEW.r1e_package_sha256
    ) THEN
      RAISE EXCEPTION 'R1F certification upstream identity mismatch';
    END IF;
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_certification_insert_guard
BEFORE INSERT ON retail.r1f_certification_runs
FOR EACH ROW EXECUTE FUNCTION retail.r1f_certification_insert_guard();

CREATE OR REPLACE FUNCTION retail.r1f_latest_certification_is_current()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      cr.certification_status='CERTIFIED'
      AND cr.certification_version='r1f-v1.0.0'
      AND cr.r1e_certification_run_id=b.r1e_certification_run_id
      AND cr.r1e_package_sha256=b.r1e_package_sha256
      AND p.certification_status='certified'
      AND cr.policy_id=p.id
      AND cr.policy_sha256=p.policy_sha256
      AND p.policy_sha256=retail.r1f_sha256_jsonb(p.policy_json)
      AND cp.certification_status='certified'
      AND cr.certification_policy_id=cp.id
      AND cr.certification_policy_sha256=cp.policy_sha256
      AND cp.policy_sha256=retail.r1f_sha256_jsonb(cp.policy_json)
      AND retail.r1f_r1e_binding_is_current()=true
    FROM retail.r1f_certification_runs cr
    JOIN retail.r1f_r1e_certification_binding b
      ON b.singleton=true
    JOIN retail.r1f_intelligence_policies p
      ON p.id=cr.policy_id
    JOIN retail.r1f_certification_policies cp
      ON cp.id=cr.certification_policy_id
    WHERE cr.id=(
      SELECT x.id
      FROM retail.r1f_certification_runs x
      WHERE x.completed_at IS NOT NULL
      ORDER BY x.completed_at DESC,x.id::text DESC
      LIMIT 1
    )
  ),false)
$$;


-- ---------- TIME-DIMENSION INTELLIGENCE ------------------------------------
CREATE OR REPLACE VIEW retail.r1f_temporal_search_intelligence AS
SELECT
  f.target_id,
  f.r1a_revision_id,
  f.r1a_revision_hash,
  f.platform_id,
  f.collection_source_id,
  f.location_fingerprint,
  f.location_context_json,
  f.weekday_iso,
  f.hour_utc,
  count(*)::int sample_jobs,
  sum(f.observations_total)::int total_observations,
  sum(f.qualified_observations)::int qualified_observations,
  CASE
    WHEN sum(f.observations_total)=0 THEN 0
    ELSE sum(f.qualified_observations)::numeric/
         sum(f.observations_total)
  END qualification_rate,
  sum(f.actual_cost_usd) total_cost_usd,
  CASE
    WHEN sum(f.qualified_observations)=0 THEN NULL
    ELSE sum(f.actual_cost_usd)/sum(f.qualified_observations)
  END cost_per_qualified_usd,
  min(f.min_qualified_price) best_qualified_price,
  max(f.completed_at) last_completed_at
FROM retail.r1f_job_facts f
JOIN retail.r1f_r1e_certification_binding b
  ON b.singleton=true
 AND b.r1e_certification_run_id=f.r1e_certification_run_id
WHERE retail.r1f_r1e_binding_is_current()=true
  AND f.fact_sha256=retail.r1f_sha256_jsonb(f.fact_document)
GROUP BY
  f.target_id,f.r1a_revision_id,f.r1a_revision_hash,
  f.platform_id,f.collection_source_id,
  f.location_fingerprint,f.location_context_json,
  f.weekday_iso,f.hour_utc;

COMMENT ON VIEW retail.r1f_temporal_search_intelligence IS
'R1F search performance by product × retailer × geography × ISO weekday × UTC hour. Intelligence only; no scheduling authority.';

-- Final R1D-consumable output is unavailable until R1F itself is certified.
CREATE OR REPLACE VIEW retail.r1f_effective_search_recommendations AS
SELECT r.*
FROM retail.r1f_search_recommendations r
JOIN retail.r1f_intelligence_policies p
  ON p.id=r.policy_id
LEFT JOIN retail.r1f_intelligence_snapshots s
  ON s.id=r.intelligence_snapshot_id
JOIN retail.r1f_r1e_certification_binding b
  ON b.singleton=true
 AND b.r1e_certification_run_id=r.r1e_certification_run_id
WHERE r.status='PROPOSED'
  AND r.expires_at>now()
  AND p.certification_status='certified'
  AND p.policy_sha256=r.policy_sha256
  AND p.policy_sha256=retail.r1f_sha256_jsonb(p.policy_json)
  AND r.recommendation_sha256=
      retail.r1f_sha256_jsonb(r.recommendation_document)
  AND retail.r1f_r1e_binding_is_current()=true
  AND retail.r1f_latest_certification_is_current()=true
  AND EXISTS(
    SELECT 1
    FROM retail.effective_compiled_search_jobs ec
    WHERE ec.id=r.compilation_id
      AND ec.target_id=r.target_id
      AND ec.r1a_revision_id=s.r1a_revision_id
      AND ec.r1a_revision_hash=s.r1a_revision_hash
      AND ec.platform_id=r.platform_id
      AND retail.r1f_sha256_jsonb(
        COALESCE(ec.normalized_job_json->'location','{}'::jsonb)
      )=r.location_fingerprint
  );

COMMENT ON VIEW retail.r1f_effective_search_recommendations IS
'R1F certified recommendations for R1D consideration only. R1D retains schedule/geo authority and must revalidate its own safety gates before acting.';

-- ---------- AUDIT / HISTORY --------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1f_history_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1F authority history is append-only';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_binding_history_guard
BEFORE UPDATE OR DELETE ON retail.r1f_r1e_binding_history
FOR EACH ROW EXECUTE FUNCTION retail.r1f_history_guard();

CREATE OR REPLACE FUNCTION retail_audit.r1f_log_retail_change()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail_audit
AS $$
DECLARE
  v_row jsonb;
  v_actor text;
BEGIN
  v_row:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  v_actor:=COALESCE(
    NULLIF(current_setting('app.actor_name',true),''),
    NULLIF(current_setting('app.actor_id',true),''),
    session_user
  );

  INSERT INTO retail_audit.retail_change_log(
    schema_name,table_name,operation,row_pk,
    old_data,new_data,changed_by
  )
  VALUES(
    TG_TABLE_SCHEMA,TG_TABLE_NAME,TG_OP,COALESCE(v_row->>'id',''),
    CASE WHEN TG_OP IN('UPDATE','DELETE') THEN to_jsonb(OLD) END,
    CASE WHEN TG_OP IN('INSERT','UPDATE') THEN to_jsonb(NEW) END,
    v_actor
  );

  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER trg_r1f_audit_policy
AFTER INSERT OR UPDATE OR DELETE ON retail.r1f_intelligence_policies
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1f_log_retail_change();

CREATE TRIGGER trg_r1f_audit_certification_policy
AFTER INSERT OR UPDATE OR DELETE ON retail.r1f_certification_policies
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1f_log_retail_change();

CREATE TRIGGER trg_r1f_audit_qa_fixtures
AFTER INSERT OR UPDATE OR DELETE ON retail.r1f_qa_fixtures
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1f_log_retail_change();

CREATE TRIGGER trg_r1f_audit_recommendations
AFTER INSERT OR UPDATE OR DELETE ON retail.r1f_search_recommendations
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1f_log_retail_change();

CREATE TRIGGER trg_r1f_audit_job_facts
AFTER INSERT OR UPDATE OR DELETE ON retail.r1f_job_facts
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1f_log_retail_change();

CREATE TRIGGER trg_r1f_audit_observation_facts
AFTER INSERT OR UPDATE OR DELETE ON retail.r1f_observation_facts
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1f_log_retail_change();

CREATE TRIGGER trg_r1f_audit_snapshots
AFTER INSERT OR UPDATE OR DELETE ON retail.r1f_intelligence_snapshots
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1f_log_retail_change();

CREATE TRIGGER trg_r1f_audit_binding
AFTER INSERT OR UPDATE OR DELETE ON retail.r1f_r1e_certification_binding
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1f_log_retail_change();

-- ---------- PRIVILEGES -------------------------------------------------------
REVOKE ALL ON FUNCTION retail.r1f_bind_r1e_certification(uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1f_certify_certification_policy(uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1f_certify_policy(uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1f_ingest_completed_job(uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1f_build_intelligence(uuid,timestamptz,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1f_generate_recommendations(uuid,timestamptz,uuid,text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION retail.r1f_ingest_completed_job(uuid,uuid,text,text)
  TO retail_r1f_worker;
GRANT EXECUTE ON FUNCTION retail.r1f_build_intelligence(uuid,timestamptz,uuid,text,text)
  TO retail_r1f_worker;
GRANT EXECUTE ON FUNCTION retail.r1f_generate_recommendations(uuid,timestamptz,uuid,text,text)
  TO retail_r1f_worker;

GRANT EXECUTE ON FUNCTION retail.r1f_bind_r1e_certification(uuid,uuid,text,text)
  TO retail_r1f_certifier;
GRANT EXECUTE ON FUNCTION retail.r1f_certify_certification_policy(uuid,uuid,text,text)
  TO retail_r1f_certifier;
GRANT EXECUTE ON FUNCTION retail.r1f_certify_policy(uuid,uuid,text,text)
  TO retail_r1f_certifier;

GRANT SELECT ON retail.r1f_effective_search_recommendations TO retail_r1f_reader;
GRANT SELECT ON retail.r1f_intelligence_snapshots TO retail_r1f_reader;
GRANT SELECT ON retail.r1f_temporal_search_intelligence TO retail_r1f_reader;
GRANT SELECT ON retail.r1f_job_facts TO retail_r1f_reader;
GRANT SELECT ON retail.r1f_observation_facts TO retail_r1f_reader;

COMMIT;
