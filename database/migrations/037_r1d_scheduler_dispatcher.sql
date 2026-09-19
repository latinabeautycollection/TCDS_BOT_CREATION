BEGIN;

CREATE SCHEMA IF NOT EXISTS retail;
CREATE SCHEMA IF NOT EXISTS retail_audit;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================================
-- TCDS RETAIL R1D — SCHEDULER / GEO ESCALATION / BUDGET / LEASING / DISPATCH
-- GREEN TIER 1 HARDENED V1 FREEZE CANDIDATE
--
-- Sole upstream execution authority:
--   retail.effective_compiled_search_jobs  (R1C V3)
--
-- R1D OWNS:
--   when to search
--   activation / geographic search depth
--   budget reservation and settlement
--   retailer rate limits
--   concurrency
--   queue materialization
--   leases
--   retries / backoff / dead letter
--   circuit breaker
--   dispatch binding to the EXISTING certified scraper
--
-- R1D DOES NOT OWN:
--   product search intent
--   retailer/source/geo route authority
--   scraper interface semantics
--   returned-product qualification
--   profitability
--   capital/purchase authority
--   checkout
-- ============================================================================

-- ---------- PRE-FLIGHT -------------------------------------------------------
DO $$
DECLARE
  v_r1c record;
BEGIN
  IF to_regclass('retail.effective_compiled_search_jobs') IS NULL
     OR to_regclass('retail.r1c_v3_state') IS NULL
     OR to_regclass('retail.r1c_certification_runs') IS NULL THEN
    RAISE EXCEPTION 'R1D requires R1C V3 authority objects';
  END IF;

  IF NOT EXISTS(
    SELECT 1 FROM retail.r1c_v3_state
    WHERE singleton=true AND hardening_version='3.0.0'
  ) THEN
    RAISE EXCEPTION 'R1D requires R1C scraper-authority hardening 3.0.0';
  END IF;

  SELECT * INTO v_r1c
  FROM retail.r1c_certification_runs
  WHERE completed_at IS NOT NULL
  ORDER BY completed_at DESC,id::text DESC
  LIMIT 1;

  IF NOT FOUND
     OR v_r1c.certification_status<>'CERTIFIED'
     OR v_r1c.certification_version<>'r1c-v3.0.0' THEN
    RAISE EXCEPTION 'R1D requires latest R1C certification = r1c-v3.0.0 CERTIFIED';
  END IF;

  IF to_regprocedure('retail.r1b_assert_runtime_adapter(uuid,text)') IS NULL
     OR to_regprocedure('retail.r1c_assert_runtime_compiler_v3(uuid,text,text,text)') IS NULL
     OR to_regprocedure('retail.r1c_assert_runtime_release(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'R1D requires R1B/R1C runtime attestation authorities';
  END IF;

  IF to_regclass('arb.process_registry') IS NULL
     OR to_regclass('arb.process_runs') IS NULL
     OR to_regclass('retail_audit.retail_change_log') IS NULL THEN
    RAISE EXCEPTION 'R1D provenance/audit dependencies missing';
  END IF;
END $$;

-- ---------- STATE / HASH -----------------------------------------------------
CREATE TABLE retail.r1d_schema_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  schema_version text NOT NULL,
  doctrine text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user
);

INSERT INTO retail.r1d_schema_state(singleton,schema_version,doctrine)
VALUES(
  true,'1.0.0',
  'R1D schedules and dispatches only current R1C V3 compiled jobs under atomic budget/rate/concurrency/lease controls. No product, profitability, capital, purchase or checkout authority.'
);

CREATE OR REPLACE FUNCTION retail.r1d_sha256_text(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT retail.r1c_sha256_text(p_text)
$$;

CREATE OR REPLACE FUNCTION retail.r1d_sha256_jsonb(p_doc jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT retail.r1d_sha256_text(p_doc::text)
$$;

-- ---------- RBAC -------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1d_reader') THEN
    CREATE ROLE retail_r1d_reader NOLOGIN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1d_scheduler') THEN
    CREATE ROLE retail_r1d_scheduler NOLOGIN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1d_dispatcher') THEN
    CREATE ROLE retail_r1d_dispatcher NOLOGIN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1d_certifier') THEN
    CREATE ROLE retail_r1d_certifier NOLOGIN;
  END IF;
END $$;

-- ---------- ARB PROCESS REGISTRY --------------------------------------------
INSERT INTO arb.process_registry(
  process_name,phase_no,process_group,description,owner_team,active_flag
)
VALUES
('RETAIL_R1D_R1C_BIND',2,'RETAIL_AUTOMATION',
 'Bind R1D to the exact latest certified R1C V3 authority.',
 'TCDS Retail Automation',true),
('RETAIL_R1D_BINDING_CERTIFY',2,'RETAIL_AUTOMATION',
 'Register/certify exact dispatcher binding for an existing certified scraper.',
 'TCDS Retail Automation',true),
('RETAIL_R1D_SCHEDULE_SYNC',2,'RETAIL_AUTOMATION',
 'Synchronize scheduling state from effective R1C compilations.',
 'TCDS Retail Automation',true),
('RETAIL_R1D_MATERIALIZE',2,'RETAIL_AUTOMATION',
 'Materialize due effective R1C compilations into idempotent dispatch jobs.',
 'TCDS Retail Automation',true),
('RETAIL_R1D_GEO_ACTIVATE',2,'RETAIL_AUTOMATION',
 'Activate/suppress pre-authorized geographic compiled routes without creating R1B authority.',
 'TCDS Retail Automation',true),
('RETAIL_R1D_JOB_CLAIM',2,'RETAIL_AUTOMATION',
 'Atomically lease a dispatch job after budget/rate/concurrency/circuit gates.',
 'TCDS Retail Automation',true),
('RETAIL_R1D_DISPATCH',2,'RETAIL_AUTOMATION',
 'Runtime-attest and dispatch the existing certified scraper.',
 'TCDS Retail Automation',true),
('RETAIL_R1D_LEASE_REAP',2,'RETAIL_AUTOMATION',
 'Reconcile expired worker leases fail-closed.',
 'TCDS Retail Automation',true),
('RETAIL_R1D_POLICY_CONFIG',2,'RETAIL_AUTOMATION',
 'Create/deactivate immutable R1D cost, budget and schedule policy versions.',
 'TCDS Retail Automation',true),
('RETAIL_R1D_CERTIFY',2,'RETAIL_AUTOMATION',
 'Execute R1D freeze-gate certification and adversarial controls.',
 'TCDS Retail Automation',true)
ON CONFLICT(process_name) DO NOTHING;

-- ---------- EXACT R1C CERTIFICATION BINDING ---------------------------------
CREATE TABLE retail.r1d_r1c_certification_binding(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  r1c_certification_run_id uuid NOT NULL
    REFERENCES retail.r1c_certification_runs(id) ON DELETE RESTRICT,
  r1c_certification_version text NOT NULL,
  r1c_package_sha256 text NOT NULL CHECK(r1c_package_sha256 ~ '^[0-9a-f]{64}$'),
  r1c_evidence_manifest_sha256 text NOT NULL CHECK(r1c_evidence_manifest_sha256 ~ '^[0-9a-f]{64}$'),
  r1c_effective_jobs_view_sha256 text NOT NULL CHECK(r1c_effective_jobs_view_sha256 ~ '^[0-9a-f]{64}$'),
  compiler_version_id uuid NOT NULL REFERENCES retail.search_compiler_versions(id) ON DELETE RESTRICT,
  compiler_authority_sha256 text NOT NULL CHECK(compiler_authority_sha256 ~ '^[0-9a-f]{64}$'),
  bound_by text NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now(),
  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE retail.r1d_r1c_binding_history(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  r1c_certification_run_id uuid NOT NULL REFERENCES retail.r1c_certification_runs(id) ON DELETE RESTRICT,
  r1c_package_sha256 text NOT NULL,
  r1c_evidence_manifest_sha256 text NOT NULL,
  r1c_effective_jobs_view_sha256 text NOT NULL,
  compiler_version_id uuid NOT NULL,
  compiler_authority_sha256 text NOT NULL,
  bound_by text NOT NULL,
  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1d_r1c_binding_is_current()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      b.r1c_certification_version='r1c-v3.0.0'
      AND cr.id=b.r1c_certification_run_id
      AND cr.certification_status='CERTIFIED'
      AND cr.certification_version='r1c-v3.0.0'
      AND cr.id=(
        SELECT x.id FROM retail.r1c_certification_runs x
        WHERE x.completed_at IS NOT NULL
        ORDER BY x.completed_at DESC,x.id::text DESC
        LIMIT 1
      )
      AND cr.r1c_package_sha256=b.r1c_package_sha256
      AND cr.evidence_manifest_sha256=b.r1c_evidence_manifest_sha256
      AND cr.compiler_version_id=b.compiler_version_id
      AND cr.compiler_authority_sha256=b.compiler_authority_sha256
      AND b.r1c_effective_jobs_view_sha256=
          retail.r1d_sha256_text(
            pg_get_viewdef('retail.effective_compiled_search_jobs'::regclass,true)
          )
      AND retail.r1c_latest_certification_is_current(b.compiler_version_id)=true
    FROM retail.r1d_r1c_certification_binding b
    JOIN retail.r1c_certification_runs cr ON cr.id=b.r1c_certification_run_id
    WHERE b.singleton=true
  ),false)
$$;

CREATE OR REPLACE FUNCTION retail.r1d_bind_r1c_certification(
  p_r1c_certification_run_id uuid,
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
  v_view_sha text;
BEGIN
  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  SELECT id INTO v_latest
  FROM retail.r1c_certification_runs
  WHERE completed_at IS NOT NULL
  ORDER BY completed_at DESC,id::text DESC
  LIMIT 1;

  IF v_latest IS DISTINCT FROM p_r1c_certification_run_id THEN
    RAISE EXCEPTION 'R1D bind blocked: supplied R1C certification is not latest';
  END IF;

  SELECT * INTO cr
  FROM retail.r1c_certification_runs
  WHERE id=p_r1c_certification_run_id
    AND certification_status='CERTIFIED'
    AND certification_version='r1c-v3.0.0';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1D bind blocked: R1C V3 CERTIFIED run required';
  END IF;

  IF retail.r1c_latest_certification_is_current(cr.compiler_version_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'R1D bind blocked: R1C compiler/release authority not current';
  END IF;

  v_view_sha:=retail.r1d_sha256_text(
    pg_get_viewdef('retail.effective_compiled_search_jobs'::regclass,true)
  );

  INSERT INTO retail.r1d_r1c_binding_history(
    r1c_certification_run_id,r1c_package_sha256,
    r1c_evidence_manifest_sha256,r1c_effective_jobs_view_sha256,
    compiler_version_id,compiler_authority_sha256,
    bound_by,source_process_run_id,source_correlation_id
  )
  VALUES(
    cr.id,cr.r1c_package_sha256,cr.evidence_manifest_sha256,
    v_view_sha,cr.compiler_version_id,cr.compiler_authority_sha256,
    p_actor,p_process_run_id,p_correlation_id
  );

  INSERT INTO retail.r1d_r1c_certification_binding(
    singleton,r1c_certification_run_id,r1c_certification_version,
    r1c_package_sha256,r1c_evidence_manifest_sha256,
    r1c_effective_jobs_view_sha256,
    compiler_version_id,compiler_authority_sha256,
    bound_by,bound_at,source_process_run_id,source_correlation_id,updated_at
  )
  VALUES(
    true,cr.id,'r1c-v3.0.0',
    cr.r1c_package_sha256,cr.evidence_manifest_sha256,
    v_view_sha,cr.compiler_version_id,cr.compiler_authority_sha256,
    p_actor,now(),p_process_run_id,p_correlation_id,now()
  )
  ON CONFLICT(singleton) DO UPDATE SET
    r1c_certification_run_id=EXCLUDED.r1c_certification_run_id,
    r1c_certification_version=EXCLUDED.r1c_certification_version,
    r1c_package_sha256=EXCLUDED.r1c_package_sha256,
    r1c_evidence_manifest_sha256=EXCLUDED.r1c_evidence_manifest_sha256,
    r1c_effective_jobs_view_sha256=EXCLUDED.r1c_effective_jobs_view_sha256,
    compiler_version_id=EXCLUDED.compiler_version_id,
    compiler_authority_sha256=EXCLUDED.compiler_authority_sha256,
    bound_by=EXCLUDED.bound_by,bound_at=EXCLUDED.bound_at,
    source_process_run_id=EXCLUDED.source_process_run_id,
    source_correlation_id=EXCLUDED.source_correlation_id,
    updated_at=now();
END $$;

-- ---------- COST PROFILES ----------------------------------------------------
CREATE TABLE retail.r1d_cost_profiles(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  collection_source_id uuid REFERENCES retail.platform_collection_sources(id) ON DELETE RESTRICT,
  collection_method text NOT NULL,
  cost_version text NOT NULL,
  unit_type text NOT NULL CHECK(unit_type IN('per_record','per_request','per_job')),
  unit_cost_usd numeric NOT NULL CHECK(unit_cost_usd>=0),
  fixed_cost_usd numeric NOT NULL DEFAULT 0 CHECK(fixed_cost_usd>=0),
  safety_multiplier numeric NOT NULL DEFAULT 1.15 CHECK(safety_multiplier>=1 AND safety_multiplier<=5),
  maximum_reservation_usd numeric CHECK(maximum_reservation_usd IS NULL OR maximum_reservation_usd>=0),
  active boolean NOT NULL DEFAULT true,
  evidence_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(evidence_json)='object'),
  evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(platform_id,collection_source_id,collection_method,cost_version)
);

CREATE OR REPLACE FUNCTION retail.r1d_prepare_cost_profile()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.evidence_sha256:=retail.r1d_sha256_jsonb(NEW.evidence_json);
  NEW.updated_at:=now();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1d_prepare_cost_profile
BEFORE INSERT OR UPDATE ON retail.r1d_cost_profiles
FOR EACH ROW EXECUTE FUNCTION retail.r1d_prepare_cost_profile();

-- ---------- BUDGET POLICIES --------------------------------------------------
CREATE TABLE retail.r1d_budget_policies(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_code text NOT NULL UNIQUE CHECK(policy_code ~ '^[A-Z0-9_:-]+$'),
  scope_type text NOT NULL CHECK(scope_type IN('GLOBAL','PLATFORM','SOURCE')),
  platform_id uuid REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  collection_source_id uuid REFERENCES retail.platform_collection_sources(id) ON DELETE RESTRICT,
  daily_limit_usd numeric NOT NULL CHECK(daily_limit_usd>0),
  budget_timezone text NOT NULL DEFAULT 'UTC' CHECK(budget_timezone='UTC'),
  active boolean NOT NULL DEFAULT true,
  effective_from timestamptz NOT NULL DEFAULT now(),
  effective_until timestamptz,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK(
    (scope_type='GLOBAL' AND platform_id IS NULL AND collection_source_id IS NULL)
    OR (scope_type='PLATFORM' AND platform_id IS NOT NULL AND collection_source_id IS NULL)
    OR (scope_type='SOURCE' AND platform_id IS NOT NULL AND collection_source_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX uq_r1d_one_active_global_budget
ON retail.r1d_budget_policies((1))
WHERE active AND scope_type='GLOBAL';

CREATE UNIQUE INDEX uq_r1d_one_active_platform_budget
ON retail.r1d_budget_policies(platform_id)
WHERE active AND scope_type='PLATFORM';

CREATE UNIQUE INDEX uq_r1d_one_active_source_budget
ON retail.r1d_budget_policies(collection_source_id)
WHERE active AND scope_type='SOURCE';

-- ---------- SCHEDULE POLICIES ------------------------------------------------
CREATE TABLE retail.r1d_schedule_policies(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_code text NOT NULL UNIQUE CHECK(policy_code ~ '^[A-Z0-9_:-]+$'),
  platform_id uuid REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  location_type text CHECK(location_type IS NULL OR location_type IN(
    'national','region','state','metro','postal_code','store'
  )),
  min_interval_seconds integer NOT NULL CHECK(min_interval_seconds BETWEEN 60 AND 2592000),
  initially_active boolean NOT NULL DEFAULT false,
  max_parallel integer NOT NULL DEFAULT 1 CHECK(max_parallel BETWEEN 1 AND 1000),
  max_attempts integer NOT NULL DEFAULT 5 CHECK(max_attempts BETWEEN 1 AND 50),
  base_backoff_seconds integer NOT NULL DEFAULT 60 CHECK(base_backoff_seconds BETWEEN 1 AND 86400),
  max_backoff_seconds integer NOT NULL DEFAULT 21600 CHECK(max_backoff_seconds BETWEEN base_backoff_seconds AND 604800),
  lease_seconds integer NOT NULL DEFAULT 900 CHECK(lease_seconds BETWEEN 30 AND 86400),
  priority integer NOT NULL DEFAULT 100 CHECK(priority BETWEEN 1 AND 999),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_r1d_schedule_policy_lookup
ON retail.r1d_schedule_policies(platform_id,location_type,active,priority);

CREATE OR REPLACE FUNCTION retail.r1d_resolve_schedule_policy(
  p_platform_id uuid,
  p_location_type text
)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT id
  FROM retail.r1d_schedule_policies
  WHERE active=true
    AND (platform_id=p_platform_id OR platform_id IS NULL)
    AND (location_type=p_location_type OR location_type IS NULL)
  ORDER BY
    (platform_id IS NOT NULL) DESC,
    (location_type IS NOT NULL) DESC,
    priority ASC,
    id::text ASC
  LIMIT 1
$$;


CREATE OR REPLACE FUNCTION retail.r1d_active_policy_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1D policy rows cannot be deleted; deactivate them';
  END IF;

  IF OLD.active=true THEN
    IF (to_jsonb(NEW)-ARRAY['active','updated_at'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['active','updated_at']) THEN
      RAISE EXCEPTION 'Active R1D policy is immutable; deactivate and create a new version';
    END IF;
    IF NEW.active IS NOT FALSE AND NEW.active IS NOT TRUE THEN
      RAISE EXCEPTION 'Invalid policy active state';
    END IF;
  ELSE
    IF NEW.active<>OLD.active THEN
      RAISE EXCEPTION 'Inactive R1D policy cannot be reactivated; create a new version';
    END IF;
  END IF;

  NEW.updated_at:=now();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1d_budget_policy_immutable
BEFORE UPDATE OR DELETE ON retail.r1d_budget_policies
FOR EACH ROW EXECUTE FUNCTION retail.r1d_active_policy_immutable();

CREATE TRIGGER trg_r1d_schedule_policy_immutable
BEFORE UPDATE OR DELETE ON retail.r1d_schedule_policies
FOR EACH ROW EXECUTE FUNCTION retail.r1d_active_policy_immutable();

CREATE TRIGGER trg_r1d_cost_policy_immutable
BEFORE UPDATE OR DELETE ON retail.r1d_cost_profiles
FOR EACH ROW EXECUTE FUNCTION retail.r1d_active_policy_immutable();

-- ---------- DISPATCH BINDINGS ------------------------------------------------
CREATE TABLE retail.r1d_dispatch_bindings(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  adapter_id uuid NOT NULL REFERENCES retail.retail_search_adapters(id) ON DELETE RESTRICT,
  scraper_asset_id uuid NOT NULL REFERENCES retail.retail_scraper_assets(id) ON DELETE RESTRICT,
  scraper_contract_id uuid NOT NULL REFERENCES retail.retail_scraper_contracts(id) ON DELETE RESTRICT,
  binding_version integer NOT NULL DEFAULT 1 CHECK(binding_version>=1),
  runner_kind text NOT NULL CHECK(runner_kind IN('node_file','npm_script','external_queue')),
  npm_script text,
  payload_delivery text NOT NULL CHECK(payload_delivery IN(
    'env','argv','stdin_json','env_plus_stdin_json'
  )),
  timeout_seconds integer NOT NULL DEFAULT 900 CHECK(timeout_seconds BETWEEN 1 AND 86400),
  max_concurrency integer NOT NULL DEFAULT 1 CHECK(max_concurrency BETWEEN 1 AND 1000),
  runner_policy_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(runner_policy_json)='object'),
  binding_document jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(binding_document)='object'),
  binding_sha256 text NOT NULL CHECK(binding_sha256 ~ '^[0-9a-f]{64}$'),
  certification_status text NOT NULL DEFAULT 'draft' CHECK(certification_status IN(
    'draft','certified','suspended','retired'
  )),
  certification_evidence_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(certification_evidence_json)='object'),
  certification_evidence_sha256 text NOT NULL CHECK(certification_evidence_sha256 ~ '^[0-9a-f]{64}$'),
  certified_by text,
  certified_at timestamptz,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(adapter_id,scraper_asset_id,scraper_contract_id,binding_version)
);

CREATE OR REPLACE FUNCTION retail.r1d_dispatch_binding_document(
  p_row retail.r1d_dispatch_bindings
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'adapter_id',p_row.adapter_id,
    'scraper_asset_id',p_row.scraper_asset_id,
    'scraper_contract_id',p_row.scraper_contract_id,
    'binding_version',p_row.binding_version,
    'runner_kind',p_row.runner_kind,
    'npm_script',p_row.npm_script,
    'payload_delivery',p_row.payload_delivery,
    'timeout_seconds',p_row.timeout_seconds,
    'max_concurrency',p_row.max_concurrency,
    'runner_policy_json',p_row.runner_policy_json
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1d_prepare_dispatch_binding()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.binding_document:=retail.r1d_dispatch_binding_document(NEW);
  NEW.binding_sha256:=retail.r1d_sha256_jsonb(NEW.binding_document);
  NEW.certification_evidence_sha256:=
    retail.r1d_sha256_jsonb(NEW.certification_evidence_json);
  NEW.updated_at:=now();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1d_prepare_dispatch_binding
BEFORE INSERT OR UPDATE ON retail.r1d_dispatch_bindings
FOR EACH ROW EXECUTE FUNCTION retail.r1d_prepare_dispatch_binding();

CREATE OR REPLACE FUNCTION retail.r1d_dispatch_binding_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1D dispatch bindings cannot be deleted; retire them';
  END IF;

  IF OLD.certification_status='certified' THEN
    IF (to_jsonb(NEW)-ARRAY['certification_status','updated_at'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['certification_status','updated_at']) THEN
      RAISE EXCEPTION 'Certified R1D dispatch binding immutable; create replacement binding';
    END IF;
    IF NEW.certification_status NOT IN('certified','suspended','retired') THEN
      RAISE EXCEPTION 'Invalid certified binding transition';
    END IF;
  END IF;

  IF OLD.certification_status IN('suspended','retired')
     AND NEW.certification_status<>OLD.certification_status
     AND NOT (OLD.certification_status='suspended' AND NEW.certification_status='retired') THEN
    RAISE EXCEPTION 'Suspended/retired binding cannot be reactivated';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1d_dispatch_binding_guard
BEFORE UPDATE OR DELETE ON retail.r1d_dispatch_bindings
FOR EACH ROW EXECUTE FUNCTION retail.r1d_dispatch_binding_guard();

CREATE OR REPLACE FUNCTION retail.r1d_dispatch_binding_is_current(p_binding_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      b.certification_status='certified'
      AND b.binding_sha256=retail.r1d_sha256_jsonb(retail.r1d_dispatch_binding_document(b))
      AND b.certification_evidence_sha256=retail.r1d_sha256_jsonb(b.certification_evidence_json)
      AND a.scraper_asset_id=b.scraper_asset_id
      AND a.scraper_contract_id=b.scraper_contract_id
      AND retail.r1b_adapter_execution_ready(a.id)=true
      AND s.discovery_status='verified'
      AND c.certification_status='certified_for_r1'
      AND c.contract_sha256=retail.r1b_sha256_jsonb(c.contract_document)
      AND (
        (b.runner_kind='node_file' AND s.implementation_authority_type='file')
        OR (b.runner_kind='npm_script' AND s.implementation_authority_type='package_tree' AND nullif(b.npm_script,'') IS NOT NULL)
        OR b.runner_kind='external_queue'
      )
    FROM retail.r1d_dispatch_bindings b
    JOIN retail.retail_search_adapters a ON a.id=b.adapter_id
    JOIN retail.retail_scraper_assets s ON s.id=b.scraper_asset_id
    JOIN retail.retail_scraper_contracts c ON c.id=b.scraper_contract_id
    WHERE b.id=p_binding_id
  ),false)
$$;


CREATE OR REPLACE FUNCTION retail.r1d_register_dispatch_binding(
  p_adapter_id uuid,
  p_runner_kind text,
  p_npm_script text,
  p_payload_delivery text,
  p_timeout_seconds integer,
  p_max_concurrency integer,
  p_runner_policy jsonb,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  a record;
  v_id uuid;
  v_version integer;
BEGIN
  SELECT * INTO a
  FROM retail.retail_search_adapters
  WHERE id=p_adapter_id
    AND retail.r1b_adapter_execution_ready(id)=true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Execution-ready R1B adapter required';
  END IF;

  IF p_runner_kind NOT IN('node_file','npm_script','external_queue') THEN
    RAISE EXCEPTION 'Unsupported runner_kind';
  END IF;
  IF p_payload_delivery NOT IN(
    'env','argv','stdin_json','env_plus_stdin_json'
  ) THEN
    RAISE EXCEPTION 'Unsupported payload_delivery';
  END IF;

  SELECT COALESCE(max(binding_version),0)+1
    INTO v_version
  FROM retail.r1d_dispatch_bindings
  WHERE adapter_id=a.id
    AND scraper_asset_id=a.scraper_asset_id
    AND scraper_contract_id=a.scraper_contract_id;

  INSERT INTO retail.r1d_dispatch_bindings(
    adapter_id,scraper_asset_id,scraper_contract_id,binding_version,
    runner_kind,npm_script,payload_delivery,
    timeout_seconds,max_concurrency,runner_policy_json,
    binding_document,binding_sha256,
    certification_status,certification_evidence_json,
    certification_evidence_sha256,created_by
  )
  VALUES(
    a.id,a.scraper_asset_id,a.scraper_contract_id,v_version,
    p_runner_kind,p_npm_script,p_payload_delivery,
    p_timeout_seconds,p_max_concurrency,
    COALESCE(p_runner_policy,'{}'::jsonb),
    '{}'::jsonb,repeat('0',64),
    'draft','{}'::jsonb,repeat('0',64),p_actor
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION retail.r1d_certify_dispatch_binding(
  p_binding_id uuid,
  p_evidence jsonb,
  p_certifier text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  b record;
  a record;
  s record;
  c record;
  v_transport text;
BEGIN
  SELECT * INTO b FROM retail.r1d_dispatch_bindings
  WHERE id=p_binding_id FOR UPDATE;
  IF NOT FOUND OR b.certification_status<>'draft' THEN
    RAISE EXCEPTION 'Dispatch binding missing/not eligible';
  END IF;

  SELECT * INTO a FROM retail.retail_search_adapters WHERE id=b.adapter_id;
  SELECT * INTO s FROM retail.retail_scraper_assets WHERE id=b.scraper_asset_id;
  SELECT * INTO c FROM retail.retail_scraper_contracts WHERE id=b.scraper_contract_id;

  IF a.scraper_asset_id<>b.scraper_asset_id
     OR a.scraper_contract_id<>b.scraper_contract_id
     OR retail.r1b_adapter_execution_ready(a.id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Dispatch binding does not match current R1B execution authority';
  END IF;

  v_transport:=c.transport;
  IF v_transport='env' AND b.payload_delivery NOT IN('env','env_plus_stdin_json') THEN
    RAISE EXCEPTION 'env contract requires env-capable payload delivery';
  ELSIF v_transport='argv' AND b.payload_delivery<>'argv' THEN
    RAISE EXCEPTION 'argv contract requires argv payload delivery';
  ELSIF v_transport='json' AND b.payload_delivery<>'stdin_json' THEN
    RAISE EXCEPTION 'json contract requires stdin_json delivery';
  ELSIF v_transport='query' AND b.payload_delivery<>'stdin_json' THEN
    RAISE EXCEPTION 'query contract requires certified JSON bridge delivery';
  ELSIF v_transport='hybrid' AND b.payload_delivery<>'env_plus_stdin_json' THEN
    RAISE EXCEPTION 'hybrid contract requires env_plus_stdin_json delivery';
  END IF;

  IF b.runner_kind='node_file'
     AND (s.implementation_authority_type<>'file' OR s.entrypoint_ref IS NULL) THEN
    RAISE EXCEPTION 'node_file binding requires file scraper asset/entrypoint';
  END IF;

  IF b.runner_kind='npm_script'
     AND (s.implementation_authority_type<>'package_tree' OR nullif(b.npm_script,'') IS NULL) THEN
    RAISE EXCEPTION 'npm_script binding requires package-tree scraper and npm script';
  END IF;

  UPDATE retail.r1d_dispatch_bindings
  SET certification_status='suspended',updated_at=now()
  WHERE adapter_id=b.adapter_id
    AND id<>b.id
    AND certification_status='certified';

  UPDATE retail.r1d_dispatch_bindings
  SET certification_status='certified',
      certification_evidence_json=p_evidence,
      certified_by=p_certifier,
      certified_at=now()
  WHERE id=p_binding_id;

  IF retail.r1d_dispatch_binding_is_current(p_binding_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Dispatch binding certification failed closed';
  END IF;
END $$;

-- ---------- SCHEDULE / GEO STATE --------------------------------------------
CREATE TABLE retail.r1d_compilation_schedule_state(
  compilation_id uuid PRIMARY KEY
    REFERENCES retail.search_job_compilations(id) ON DELETE RESTRICT,
  schedule_policy_id uuid NOT NULL REFERENCES retail.r1d_schedule_policies(id) ON DELETE RESTRICT,
  activation_state text NOT NULL CHECK(activation_state IN(
    'baseline','activated','suppressed','retired'
  )),
  activation_source text NOT NULL CHECK(activation_source IN(
    'policy','signal','manual','system'
  )),
  activation_score numeric,
  activation_reason text,
  next_eligible_at timestamptz NOT NULL,
  last_materialized_at timestamptz,
  last_succeeded_at timestamptz,
  consecutive_failures integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1d_sync_schedule_state(
  p_now timestamptz,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  r record;
  v_policy retail.r1d_schedule_policies%ROWTYPE;
  v_count integer:=0;
BEGIN
  IF retail.r1d_r1c_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1D schedule sync blocked: R1C binding not current';
  END IF;

  FOR r IN
    SELECT j.id compilation_id,j.platform_id,j.location_id,
           er.location_type
    FROM retail.effective_compiled_search_jobs j
    JOIN retail.effective_search_routes er ON er.route_id=j.route_id
    ORDER BY j.id
  LOOP
    SELECT * INTO v_policy
    FROM retail.r1d_schedule_policies
    WHERE id=retail.r1d_resolve_schedule_policy(
      r.platform_id,COALESCE(r.location_type,'national')
    );

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    INSERT INTO retail.r1d_compilation_schedule_state(
      compilation_id,schedule_policy_id,activation_state,
      activation_source,next_eligible_at
    )
    VALUES(
      r.compilation_id,v_policy.id,
      CASE WHEN v_policy.initially_active THEN 'baseline' ELSE 'suppressed' END,
      'policy',p_now
    )
    ON CONFLICT(compilation_id) DO UPDATE SET
      schedule_policy_id=EXCLUDED.schedule_policy_id,
      updated_at=now();

    v_count:=v_count+1;
  END LOOP;

  UPDATE retail.r1d_compilation_schedule_state s
  SET activation_state='retired',updated_at=now()
  WHERE activation_state<>'retired'
    AND NOT EXISTS(
      SELECT 1 FROM retail.effective_compiled_search_jobs j
      WHERE j.id=s.compilation_id
    );

  RETURN v_count;
END $$;

CREATE OR REPLACE FUNCTION retail.r1d_set_geo_activation(
  p_compilation_id uuid,
  p_state text,
  p_source text,
  p_score numeric,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
BEGIN
  IF p_state NOT IN('activated','suppressed') THEN
    RAISE EXCEPTION 'Geo activation state must be activated/suppressed';
  END IF;
  IF p_source NOT IN('signal','manual','system') THEN
    RAISE EXCEPTION 'Geo activation source invalid';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM retail.effective_compiled_search_jobs
    WHERE id=p_compilation_id
  ) THEN
    RAISE EXCEPTION 'Cannot activate non-effective compilation';
  END IF;

  UPDATE retail.r1d_compilation_schedule_state
  SET activation_state=p_state,
      activation_source=p_source,
      activation_score=p_score,
      activation_reason=p_reason,
      next_eligible_at=least(next_eligible_at,now()),
      updated_at=now()
  WHERE compilation_id=p_compilation_id
    AND activation_state<>'retired';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1D schedule state missing/retired';
  END IF;
END $$;


CREATE TABLE retail.r1d_geo_activation_events(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  parent_compilation_id uuid REFERENCES retail.search_job_compilations(id) ON DELETE RESTRICT,
  child_compilation_id uuid NOT NULL REFERENCES retail.search_job_compilations(id) ON DELETE RESTRICT,
  signal_type text NOT NULL,
  signal_score numeric,
  reason text,
  activated_by text NOT NULL,
  process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  correlation_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1d_activate_geo_children(
  p_parent_compilation_id uuid,
  p_signal_type text,
  p_signal_score numeric,
  p_reason text,
  p_max_children integer,
  p_actor text,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  parent_rec record;
  child_rec record;
  v_count integer:=0;
BEGIN
  IF p_max_children<1 OR p_max_children>100 THEN
    RAISE EXCEPTION 'Geo escalation max_children must be 1..100';
  END IF;

  SELECT j.id,j.target_id,j.platform_id,j.route_id,
         er.location_id
  INTO parent_rec
  FROM retail.effective_compiled_search_jobs j
  JOIN retail.effective_search_routes er ON er.route_id=j.route_id
  WHERE j.id=p_parent_compilation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent compilation is not effective';
  END IF;

  FOR child_rec IN
    SELECT cj.id compilation_id
    FROM retail.effective_compiled_search_jobs cj
    JOIN retail.effective_search_routes cer ON cer.route_id=cj.route_id
    JOIN retail.search_locations cl ON cl.id=cer.location_id
    JOIN retail.r1d_compilation_schedule_state ss ON ss.compilation_id=cj.id
    WHERE cj.target_id=parent_rec.target_id
      AND cj.platform_id=parent_rec.platform_id
      AND cj.id<>parent_rec.id
      AND ss.activation_state='suppressed'
      AND (
        (parent_rec.location_id IS NOT NULL AND cl.parent_location_id=parent_rec.location_id)
        OR
        (parent_rec.location_id IS NULL AND cl.parent_location_id IS NULL)
      )
    ORDER BY cl.location_type,cl.location_code,cj.id
    LIMIT p_max_children
    FOR UPDATE OF ss SKIP LOCKED
  LOOP
    UPDATE retail.r1d_compilation_schedule_state
    SET activation_state='activated',
        activation_source='signal',
        activation_score=p_signal_score,
        activation_reason=p_reason,
        next_eligible_at=least(next_eligible_at,now()),
        updated_at=now()
    WHERE compilation_id=child_rec.compilation_id;

    INSERT INTO retail.r1d_geo_activation_events(
      parent_compilation_id,child_compilation_id,
      signal_type,signal_score,reason,activated_by,
      process_run_id,correlation_id
    )
    VALUES(
      p_parent_compilation_id,child_rec.compilation_id,
      p_signal_type,p_signal_score,p_reason,p_actor,
      p_process_run_id,p_correlation_id
    );

    v_count:=v_count+1;
  END LOOP;

  RETURN v_count;
END $$;

-- ---------- CIRCUIT BREAKER --------------------------------------------------
CREATE TABLE retail.r1d_circuit_breakers(
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  collection_source_id uuid REFERENCES retail.platform_collection_sources(id) ON DELETE RESTRICT,
  state text NOT NULL DEFAULT 'closed' CHECK(state IN('closed','open','half_open')),
  consecutive_failures integer NOT NULL DEFAULT 0,
  failure_threshold integer NOT NULL DEFAULT 5 CHECK(failure_threshold BETWEEN 1 AND 100),
  open_seconds integer NOT NULL DEFAULT 900 CHECK(open_seconds BETWEEN 30 AND 86400),
  opened_at timestamptz,
  open_until timestamptz,
  last_failure_at timestamptz,
  last_success_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(platform_id,collection_source_id)
);

CREATE OR REPLACE FUNCTION retail.r1d_circuit_allows(
  p_platform_id uuid,
  p_source_id uuid,
  p_now timestamptz
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      state='closed'
      OR (state='open' AND open_until<=p_now)
      OR state='half_open'
    FROM retail.r1d_circuit_breakers
    WHERE platform_id=p_platform_id
      AND collection_source_id IS NOT DISTINCT FROM p_source_id
  ),true)
$$;

-- ---------- DISPATCH JOBS ----------------------------------------------------
CREATE TABLE retail.r1d_dispatch_jobs(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispatch_key text NOT NULL UNIQUE CHECK(dispatch_key ~ '^[0-9a-f]{64}$'),
  compilation_id uuid NOT NULL REFERENCES retail.search_job_compilations(id) ON DELETE RESTRICT,
  route_authority_hash text NOT NULL CHECK(route_authority_hash ~ '^[0-9a-f]{64}$'),
  adapter_payload_sha256 text NOT NULL CHECK(adapter_payload_sha256 ~ '^[0-9a-f]{64}$'),
  compiler_authority_sha256 text NOT NULL CHECK(compiler_authority_sha256 ~ '^[0-9a-f]{64}$'),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  collection_source_id uuid NOT NULL REFERENCES retail.platform_collection_sources(id) ON DELETE RESTRICT,
  adapter_id uuid NOT NULL REFERENCES retail.retail_search_adapters(id) ON DELETE RESTRICT,
  location_id uuid REFERENCES retail.search_locations(id) ON DELETE RESTRICT,
  dispatch_binding_id uuid NOT NULL REFERENCES retail.r1d_dispatch_bindings(id) ON DELETE RESTRICT,
  cost_profile_id uuid NOT NULL REFERENCES retail.r1d_cost_profiles(id) ON DELETE RESTRICT,
  schedule_policy_id uuid NOT NULL REFERENCES retail.r1d_schedule_policies(id) ON DELETE RESTRICT,
  scheduled_for timestamptz NOT NULL,
  priority integer NOT NULL DEFAULT 100 CHECK(priority BETWEEN 1 AND 999),
  estimated_cost_usd numeric NOT NULL CHECK(estimated_cost_usd>=0),
  status text NOT NULL DEFAULT 'queued' CHECK(status IN(
    'queued','leased','dispatching','succeeded',
    'retry_wait','dead_letter','cancelled'
  )),
  attempt_count integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  lease_token uuid,
  leased_by text,
  leased_at timestamptz,
  lease_expires_at timestamptz,
  budget_reservation_group uuid,
  last_error_code text,
  last_error_message text,
  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_r1d_jobs_claim
ON retail.r1d_dispatch_jobs(status,next_attempt_at,priority,scheduled_for);

CREATE INDEX idx_r1d_jobs_platform_state
ON retail.r1d_dispatch_jobs(platform_id,status);


CREATE OR REPLACE FUNCTION retail.r1d_dispatch_job_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1D dispatch jobs cannot be deleted';
  END IF;

  IF (to_jsonb(NEW)-ARRAY[
        'status','attempt_count','next_attempt_at',
        'lease_token','leased_by','leased_at','lease_expires_at',
        'budget_reservation_group','last_error_code','last_error_message',
        'updated_at'
      ])
     IS DISTINCT FROM
     (to_jsonb(OLD)-ARRAY[
        'status','attempt_count','next_attempt_at',
        'lease_token','leased_by','leased_at','lease_expires_at',
        'budget_reservation_group','last_error_code','last_error_message',
        'updated_at'
      ]) THEN
    RAISE EXCEPTION 'R1D dispatch authority fields are immutable after creation';
  END IF;

  IF OLD.status IN('succeeded','dead_letter','cancelled')
     AND NEW.status<>OLD.status THEN
    RAISE EXCEPTION 'Terminal R1D job status cannot be reversed';
  END IF;

  IF NEW.status<>OLD.status AND NOT (
    (OLD.status='queued' AND NEW.status IN('leased','cancelled'))
    OR (OLD.status='retry_wait' AND NEW.status IN('leased','dead_letter','cancelled'))
    OR (OLD.status='leased' AND NEW.status IN('dispatching','retry_wait','dead_letter','cancelled'))
    OR (OLD.status='dispatching' AND NEW.status IN('succeeded','retry_wait','dead_letter','cancelled'))
  ) THEN
    RAISE EXCEPTION 'Invalid R1D job transition % -> %',OLD.status,NEW.status;
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1d_dispatch_job_guard
BEFORE UPDATE OR DELETE ON retail.r1d_dispatch_jobs
FOR EACH ROW EXECUTE FUNCTION retail.r1d_dispatch_job_guard();

-- ---------- BUDGET RESERVATIONS / LEDGER ------------------------------------
CREATE TABLE retail.r1d_budget_reservations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_group uuid NOT NULL,
  job_id uuid NOT NULL REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  budget_policy_id uuid NOT NULL REFERENCES retail.r1d_budget_policies(id) ON DELETE RESTRICT,
  budget_day date NOT NULL,
  reserved_usd numeric NOT NULL CHECK(reserved_usd>=0),
  actual_usd numeric CHECK(actual_usd IS NULL OR actual_usd>=0),
  status text NOT NULL CHECK(status IN('reserved','settled','released')),
  cost_basis text CHECK(cost_basis IS NULL OR cost_basis IN('actual','estimated')),
  created_at timestamptz NOT NULL DEFAULT now(),
  settled_at timestamptz,
  UNIQUE(reservation_group,budget_policy_id)
);

CREATE TABLE retail.r1d_budget_ledger(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reservation_group uuid NOT NULL,
  job_id uuid NOT NULL REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  budget_policy_id uuid NOT NULL REFERENCES retail.r1d_budget_policies(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK(event_type IN('RESERVE','SETTLE','RELEASE')),
  amount_usd numeric NOT NULL CHECK(amount_usd>=0),
  process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  correlation_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1d_reserve_budget_for_job(
  p_job_id uuid,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  j retail.r1d_dispatch_jobs%ROWTYPE;
  p retail.r1d_budget_policies%ROWTYPE;
  v_group uuid:=gen_random_uuid();
  v_day date:=(now() AT TIME ZONE 'UTC')::date;
  v_used numeric;
  v_count integer:=0;
BEGIN
  SELECT * INTO j FROM retail.r1d_dispatch_jobs
  WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Budget reservation job missing'; END IF;

  IF j.budget_reservation_group IS NOT NULL
     AND EXISTS(
       SELECT 1 FROM retail.r1d_budget_reservations
       WHERE reservation_group=j.budget_reservation_group
         AND status='reserved'
     ) THEN
    RETURN j.budget_reservation_group;
  END IF;

  IF j.budget_reservation_group IS NOT NULL THEN
    UPDATE retail.r1d_dispatch_jobs
    SET budget_reservation_group=NULL,updated_at=now()
    WHERE id=j.id;
    j.budget_reservation_group:=NULL;
  END IF;

  IF NOT EXISTS(
    SELECT 1 FROM retail.r1d_budget_policies
    WHERE active=true AND scope_type='GLOBAL'
      AND effective_from<=now()
      AND (effective_until IS NULL OR effective_until>now())
  ) THEN
    RAISE EXCEPTION 'R1D fail-closed: active GLOBAL daily budget policy required';
  END IF;

  -- Lock every applicable policy in deterministic order BEFORE inserting.
  FOR p IN
    SELECT *
    FROM retail.r1d_budget_policies
    WHERE active=true
      AND effective_from<=now()
      AND (effective_until IS NULL OR effective_until>now())
      AND (
        scope_type='GLOBAL'
        OR (scope_type='PLATFORM' AND platform_id=j.platform_id)
        OR (scope_type='SOURCE' AND collection_source_id=j.collection_source_id)
      )
    ORDER BY scope_type,id
    FOR UPDATE
  LOOP
    SELECT COALESCE(sum(
      CASE
        WHEN status='settled' THEN COALESCE(actual_usd,reserved_usd)
        WHEN status='reserved' THEN reserved_usd
        ELSE 0
      END
    ),0)
    INTO v_used
    FROM retail.r1d_budget_reservations
    WHERE budget_policy_id=p.id
      AND budget_day=v_day;

    IF v_used+j.estimated_cost_usd>p.daily_limit_usd THEN
      RETURN NULL;
    END IF;
    v_count:=v_count+1;
  END LOOP;

  IF v_count=0 THEN
    RAISE EXCEPTION 'R1D fail-closed: no applicable budget policies';
  END IF;

  INSERT INTO retail.r1d_budget_reservations(
    reservation_group,job_id,budget_policy_id,budget_day,
    reserved_usd,status
  )
  SELECT
    v_group,j.id,p.id,v_day,j.estimated_cost_usd,'reserved'
  FROM retail.r1d_budget_policies p
  WHERE p.active=true
    AND p.effective_from<=now()
    AND (p.effective_until IS NULL OR p.effective_until>now())
    AND (
      p.scope_type='GLOBAL'
      OR (p.scope_type='PLATFORM' AND p.platform_id=j.platform_id)
      OR (p.scope_type='SOURCE' AND p.collection_source_id=j.collection_source_id)
    );

  INSERT INTO retail.r1d_budget_ledger(
    reservation_group,job_id,budget_policy_id,event_type,
    amount_usd,process_run_id,correlation_id
  )
  SELECT
    reservation_group,job_id,budget_policy_id,'RESERVE',
    reserved_usd,p_process_run_id,p_correlation_id
  FROM retail.r1d_budget_reservations
  WHERE reservation_group=v_group;

  UPDATE retail.r1d_dispatch_jobs
  SET budget_reservation_group=v_group,updated_at=now()
  WHERE id=j.id;

  RETURN v_group;
END $$;

CREATE OR REPLACE FUNCTION retail.r1d_settle_budget(
  p_job_id uuid,
  p_actual_cost_usd numeric,
  p_cost_basis text,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_actual numeric;
BEGIN
  IF p_actual_cost_usd IS NOT NULL AND p_actual_cost_usd<0 THEN
    RAISE EXCEPTION 'Actual cost cannot be negative';
  END IF;
  IF p_cost_basis NOT IN('actual','estimated') THEN
    RAISE EXCEPTION 'cost_basis must be actual/estimated';
  END IF;

  SELECT COALESCE(p_actual_cost_usd,max(reserved_usd))
  INTO v_actual
  FROM retail.r1d_budget_reservations
  WHERE job_id=p_job_id AND status='reserved';

  IF v_actual IS NULL THEN
    RETURN;
  END IF;

  UPDATE retail.r1d_budget_reservations
  SET actual_usd=v_actual,status='settled',
      cost_basis=p_cost_basis,settled_at=now()
  WHERE job_id=p_job_id AND status='reserved';

  INSERT INTO retail.r1d_budget_ledger(
    reservation_group,job_id,budget_policy_id,event_type,
    amount_usd,process_run_id,correlation_id
  )
  SELECT
    reservation_group,job_id,budget_policy_id,'SETTLE',
    v_actual,p_process_run_id,p_correlation_id
  FROM retail.r1d_budget_reservations
  WHERE job_id=p_job_id AND status='settled'
    AND settled_at>=now()-interval '5 seconds';

  UPDATE retail.r1d_dispatch_jobs
  SET budget_reservation_group=NULL,updated_at=now()
  WHERE id=p_job_id;
END $$;

CREATE OR REPLACE FUNCTION retail.r1d_release_budget(
  p_job_id uuid,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
BEGIN
  INSERT INTO retail.r1d_budget_ledger(
    reservation_group,job_id,budget_policy_id,event_type,
    amount_usd,process_run_id,correlation_id
  )
  SELECT
    reservation_group,job_id,budget_policy_id,'RELEASE',
    reserved_usd,p_process_run_id,p_correlation_id
  FROM retail.r1d_budget_reservations
  WHERE job_id=p_job_id AND status='reserved';

  UPDATE retail.r1d_budget_reservations
  SET status='released',settled_at=now()
  WHERE job_id=p_job_id AND status='reserved';

  UPDATE retail.r1d_dispatch_jobs
  SET budget_reservation_group=NULL,updated_at=now()
  WHERE id=p_job_id;
END $$;

-- ---------- RATE LIMIT RESERVATION ------------------------------------------
CREATE TABLE retail.r1d_rate_usage(
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  bucket_kind text NOT NULL CHECK(bucket_kind IN('hour','day')),
  bucket_start timestamptz NOT NULL,
  reserved_count integer NOT NULL DEFAULT 0 CHECK(reserved_count>=0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(platform_id,bucket_kind,bucket_start)
);

CREATE OR REPLACE FUNCTION retail.r1d_reserve_rate_slot(
  p_platform_id uuid,
  p_now timestamptz
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  v_hour timestamptz:=date_trunc('hour',p_now);
  v_day timestamptz:=date_trunc('day',p_now AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_hour_max integer;
  v_day_max integer;
  v_hour_used integer;
  v_day_used integer;
BEGIN
  SELECT max_hourly_requests,max_daily_requests
  INTO v_hour_max,v_day_max
  FROM retail.retail_platforms
  WHERE id=p_platform_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Platform missing'; END IF;

  INSERT INTO retail.r1d_rate_usage(platform_id,bucket_kind,bucket_start)
  VALUES(p_platform_id,'hour',v_hour)
  ON CONFLICT DO NOTHING;

  INSERT INTO retail.r1d_rate_usage(platform_id,bucket_kind,bucket_start)
  VALUES(p_platform_id,'day',v_day)
  ON CONFLICT DO NOTHING;

  SELECT reserved_count INTO v_hour_used
  FROM retail.r1d_rate_usage
  WHERE platform_id=p_platform_id AND bucket_kind='hour' AND bucket_start=v_hour
  FOR UPDATE;

  SELECT reserved_count INTO v_day_used
  FROM retail.r1d_rate_usage
  WHERE platform_id=p_platform_id AND bucket_kind='day' AND bucket_start=v_day
  FOR UPDATE;

  IF (v_hour_max IS NOT NULL AND v_hour_used>=v_hour_max)
     OR (v_day_max IS NOT NULL AND v_day_used>=v_day_max) THEN
    RETURN false;
  END IF;

  UPDATE retail.r1d_rate_usage
  SET reserved_count=reserved_count+1,updated_at=now()
  WHERE platform_id=p_platform_id AND bucket_kind='hour' AND bucket_start=v_hour;

  UPDATE retail.r1d_rate_usage
  SET reserved_count=reserved_count+1,updated_at=now()
  WHERE platform_id=p_platform_id AND bucket_kind='day' AND bucket_start=v_day;

  RETURN true;
END $$;

-- ---------- DISPATCH ATTEMPTS / OUTBOX / DEAD LETTER ------------------------
CREATE TABLE retail.r1d_dispatch_attempts(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job_id uuid NOT NULL REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  attempt_no integer NOT NULL,
  worker_id text NOT NULL,
  lease_token uuid NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  success boolean,
  exit_code integer,
  error_code text,
  error_message text,
  stdout_tail text,
  stderr_tail text,
  stdout_sha256 text,
  stderr_sha256 text,
  metrics_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  actual_cost_usd numeric,
  cost_basis text CHECK(cost_basis IS NULL OR cost_basis IN('actual','estimated')),
  UNIQUE(job_id,attempt_no)
);

CREATE TABLE retail.r1d_dispatch_outbox(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job_id uuid NOT NULL UNIQUE REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  binding_id uuid NOT NULL REFERENCES retail.r1d_dispatch_bindings(id) ON DELETE RESTRICT,
  lease_token uuid NOT NULL,
  payload_json jsonb NOT NULL,
  payload_sha256 text NOT NULL CHECK(payload_sha256 ~ '^[0-9a-f]{64}$'),
  status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','delivered','failed','cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz
);

CREATE TABLE retail.r1d_dead_letters(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job_id uuid NOT NULL UNIQUE REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  error_code text NOT NULL,
  error_message text NOT NULL,
  attempt_count integer NOT NULL,
  payload_snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- COST ESTIMATION --------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1d_resolve_cost_profile(
  p_platform_id uuid,
  p_source_id uuid,
  p_collection_method text
)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT id
  FROM retail.r1d_cost_profiles
  WHERE active=true
    AND platform_id=p_platform_id
    AND collection_method=p_collection_method
    AND (collection_source_id=p_source_id OR collection_source_id IS NULL)
  ORDER BY (collection_source_id IS NOT NULL) DESC,created_at DESC,id::text
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION retail.r1d_estimate_cost(
  p_compilation_id uuid,
  p_cost_profile_id uuid
)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  j record;
  c retail.r1d_cost_profiles%ROWTYPE;
  v_units numeric:=1;
  v_cost numeric;
BEGIN
  SELECT * INTO j
  FROM retail.effective_compiled_search_jobs
  WHERE id=p_compilation_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Compilation not effective'; END IF;

  SELECT * INTO c
  FROM retail.r1d_cost_profiles
  WHERE id=p_cost_profile_id AND active=true;

  IF NOT FOUND THEN RAISE EXCEPTION 'Active cost profile required'; END IF;

  IF c.unit_type='per_record' THEN
    v_units:=COALESCE(
      nullif(j.normalized_job_json#>>'{target,discovery_result_limit}','')::numeric,
      1
    );
  ELSIF c.unit_type IN('per_request','per_job') THEN
    v_units:=1;
  END IF;

  v_cost:=(c.fixed_cost_usd+(c.unit_cost_usd*v_units))*c.safety_multiplier;

  IF c.maximum_reservation_usd IS NOT NULL
     AND v_cost>c.maximum_reservation_usd THEN
    RAISE EXCEPTION
      'Estimated dispatch cost % exceeds certified maximum reservation %',
      v_cost,c.maximum_reservation_usd;
  END IF;

  RETURN round(v_cost,6);
END $$;

-- ---------- MATERIALIZATION --------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1d_materialize_due_jobs(
  p_now timestamptz,
  p_limit integer,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  x record;
  b record;
  cp uuid;
  v_cost numeric;
  v_bucket bigint;
  v_key text;
  v_count integer:=0;
BEGIN
  IF retail.r1d_r1c_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1D materialization blocked: R1C V3 binding not current';
  END IF;
  IF p_limit<1 OR p_limit>10000 THEN
    RAISE EXCEPTION 'Materialize limit out of range';
  END IF;

  FOR x IN
    SELECT
      s.compilation_id,s.schedule_policy_id,s.next_eligible_at,
      sp.min_interval_seconds,sp.max_attempts,sp.priority,
      j.route_authority_hash,j.adapter_payload_sha256,
      j.compiler_authority_sha256,j.platform_id,j.collection_source_id,
      j.adapter_id,j.location_id,
      er.collection_method
    FROM retail.r1d_compilation_schedule_state s
    JOIN retail.r1d_schedule_policies sp ON sp.id=s.schedule_policy_id AND sp.active
    JOIN retail.effective_compiled_search_jobs j ON j.id=s.compilation_id
    JOIN retail.effective_search_routes er ON er.route_id=j.route_id
    WHERE s.activation_state IN('baseline','activated')
      AND s.next_eligible_at<=p_now
    ORDER BY sp.priority,s.next_eligible_at,j.id
    LIMIT p_limit
    FOR UPDATE OF s SKIP LOCKED
  LOOP
    SELECT * INTO b
    FROM retail.r1d_dispatch_bindings
    WHERE adapter_id=x.adapter_id
      AND retail.r1d_dispatch_binding_is_current(id)=true
    ORDER BY certified_at DESC,id::text
    LIMIT 1;

    IF NOT FOUND THEN CONTINUE; END IF;

    cp:=retail.r1d_resolve_cost_profile(
      x.platform_id,x.collection_source_id,x.collection_method
    );
    IF cp IS NULL THEN CONTINUE; END IF;

    v_cost:=retail.r1d_estimate_cost(x.compilation_id,cp);
    v_bucket:=floor(extract(epoch from p_now)/x.min_interval_seconds)::bigint;
    v_key:=retail.r1d_sha256_text(
      x.compilation_id::text||':'||x.route_authority_hash||':'||
      x.adapter_payload_sha256||':'||v_bucket::text
    );

    INSERT INTO retail.r1d_dispatch_jobs(
      dispatch_key,compilation_id,route_authority_hash,
      adapter_payload_sha256,compiler_authority_sha256,
      platform_id,collection_source_id,adapter_id,location_id,
      dispatch_binding_id,cost_profile_id,schedule_policy_id,
      scheduled_for,priority,estimated_cost_usd,max_attempts,
      next_attempt_at,source_process_run_id,source_correlation_id
    )
    VALUES(
      v_key,x.compilation_id,x.route_authority_hash,
      x.adapter_payload_sha256,x.compiler_authority_sha256,
      x.platform_id,x.collection_source_id,x.adapter_id,x.location_id,
      b.id,cp,x.schedule_policy_id,
      p_now,x.priority,v_cost,x.max_attempts,
      p_now,p_process_run_id,p_correlation_id
    )
    ON CONFLICT(dispatch_key) DO NOTHING;

    UPDATE retail.r1d_compilation_schedule_state
    SET last_materialized_at=p_now,
        next_eligible_at=p_now+make_interval(secs=>x.min_interval_seconds),
        updated_at=now()
    WHERE compilation_id=x.compilation_id;

    v_count:=v_count+1;
  END LOOP;

  RETURN v_count;
END $$;

-- ---------- CLAIM / LEASE ----------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1d_claim_next_job(
  p_worker_id text,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS TABLE(
  job_id uuid,
  lease_token uuid,
  lease_expires_at timestamptz,
  compilation_id uuid,
  adapter_id uuid,
  dispatch_binding_id uuid,
  adapter_payload_json jsonb,
  normalized_job_json jsonb,
  estimated_cost_usd numeric
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  j retail.r1d_dispatch_jobs%ROWTYPE;
  sp retail.r1d_schedule_policies%ROWTYPE;
  db retail.r1d_dispatch_bindings%ROWTYPE;
  v_token uuid;
  v_budget uuid;
  v_running integer;
  v_rate boolean;
BEGIN
  IF retail.r1d_r1c_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1D claim blocked: R1C V3 binding not current';
  END IF;

  FOR j IN
    SELECT q.*
    FROM retail.r1d_dispatch_jobs q
    JOIN retail.effective_compiled_search_jobs ec ON ec.id=q.compilation_id
    WHERE q.status IN('queued','retry_wait')
      AND q.next_attempt_at<=now()
      AND retail.r1d_dispatch_binding_is_current(q.dispatch_binding_id)=true
      AND retail.r1d_circuit_allows(q.platform_id,q.collection_source_id,now())=true
    ORDER BY q.priority,q.scheduled_for,q.id
    FOR UPDATE OF q SKIP LOCKED
    LIMIT 50
  LOOP
    IF NOT EXISTS(
      SELECT 1 FROM retail.effective_compiled_search_jobs ec
      WHERE ec.id=j.compilation_id
        AND ec.route_authority_hash=j.route_authority_hash
        AND ec.adapter_payload_sha256=j.adapter_payload_sha256
        AND ec.compiler_authority_sha256=j.compiler_authority_sha256
    ) THEN
      UPDATE retail.r1d_dispatch_jobs
      SET status='cancelled',
          last_error_code='UPSTREAM_AUTHORITY_CHANGED',
          last_error_message='R1C compilation authority no longer matches queued job',
          updated_at=now()
      WHERE id=j.id;
      CONTINUE;
    END IF;

    SELECT * INTO sp FROM retail.r1d_schedule_policies
    WHERE id=j.schedule_policy_id AND active=true;
    SELECT * INTO db FROM retail.r1d_dispatch_bindings
    WHERE id=j.dispatch_binding_id
      AND retail.r1d_dispatch_binding_is_current(id)=true;

    IF NOT FOUND THEN CONTINUE; END IF;

    -- Serialize concurrency checks for this platform in the current transaction.
    PERFORM pg_advisory_xact_lock(
      hashtextextended('r1d-platform:'||j.platform_id::text,0)
    );

    SELECT count(*)::int INTO v_running
    FROM retail.r1d_dispatch_jobs
    WHERE platform_id=j.platform_id
      AND status IN('leased','dispatching')
      AND lease_expires_at>now();

    IF v_running>=sp.max_parallel THEN CONTINUE; END IF;

    SELECT count(*)::int INTO v_running
    FROM retail.r1d_dispatch_jobs
    WHERE dispatch_binding_id=j.dispatch_binding_id
      AND status IN('leased','dispatching')
      AND lease_expires_at>now();

    IF v_running>=db.max_concurrency THEN CONTINUE; END IF;

    v_budget:=retail.r1d_reserve_budget_for_job(
      j.id,p_process_run_id,p_correlation_id
    );
    IF v_budget IS NULL THEN CONTINUE; END IF;

    v_rate:=retail.r1d_reserve_rate_slot(j.platform_id,now());
    IF v_rate IS NOT TRUE THEN
      PERFORM retail.r1d_release_budget(
        j.id,p_process_run_id,p_correlation_id
      );
      CONTINUE;
    END IF;

    v_token:=gen_random_uuid();

    UPDATE retail.r1d_dispatch_jobs
    SET status='leased',
        attempt_count=attempt_count+1,
        lease_token=v_token,
        leased_by=p_worker_id,
        leased_at=now(),
        lease_expires_at=now()+make_interval(secs=>sp.lease_seconds),
        budget_reservation_group=v_budget,
        updated_at=now()
    WHERE id=j.id;

    INSERT INTO retail.r1d_dispatch_attempts(
      job_id,attempt_no,worker_id,lease_token
    )
    VALUES(j.id,j.attempt_count+1,p_worker_id,v_token);

    RETURN QUERY
    SELECT
      j.id,v_token,now()+make_interval(secs=>sp.lease_seconds),
      ec.id,ec.adapter_id,j.dispatch_binding_id,
      ec.adapter_payload_json,ec.normalized_job_json,j.estimated_cost_usd
    FROM retail.effective_compiled_search_jobs ec
    WHERE ec.id=j.compilation_id;

    RETURN;
  END LOOP;

  RETURN;
END $$;

CREATE OR REPLACE FUNCTION retail.r1d_mark_dispatching(
  p_job_id uuid,
  p_lease_token uuid
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
BEGIN
  UPDATE retail.r1d_dispatch_jobs
  SET status='dispatching',updated_at=now()
  WHERE id=p_job_id
    AND status='leased'
    AND lease_token=p_lease_token
    AND lease_expires_at>now();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Lease invalid/expired or job not leased';
  END IF;
END $$;


CREATE OR REPLACE FUNCTION retail.r1d_fail_pre_dispatch(
  p_job_id uuid,
  p_lease_token uuid,
  p_error_code text,
  p_error_message text,
  p_terminal boolean,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  j retail.r1d_dispatch_jobs%ROWTYPE;
  sp retail.r1d_schedule_policies%ROWTYPE;
  v_backoff integer;
BEGIN
  SELECT * INTO j
  FROM retail.r1d_dispatch_jobs
  WHERE id=p_job_id FOR UPDATE;

  IF NOT FOUND
     OR j.status<>'leased'
     OR j.lease_token IS DISTINCT FROM p_lease_token THEN
    RAISE EXCEPTION 'Pre-dispatch failure blocked: invalid active lease';
  END IF;

  SELECT * INTO sp FROM retail.r1d_schedule_policies
  WHERE id=j.schedule_policy_id;

  PERFORM retail.r1d_release_budget(
    j.id,p_process_run_id,p_correlation_id
  );

  UPDATE retail.r1d_dispatch_attempts
  SET completed_at=now(),success=false,
      error_code=p_error_code,
      error_message=left(p_error_message,4000),
      cost_basis='estimated',actual_cost_usd=0
  WHERE job_id=j.id AND attempt_no=j.attempt_count;

  IF p_terminal OR j.attempt_count>=j.max_attempts THEN
    UPDATE retail.r1d_dispatch_jobs
    SET status='dead_letter',
        lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
        last_error_code=p_error_code,
        last_error_message=left(p_error_message,4000),
        updated_at=now()
    WHERE id=j.id;

    INSERT INTO retail.r1d_dead_letters(
      job_id,error_code,error_message,attempt_count,payload_snapshot
    )
    VALUES(
      j.id,COALESCE(p_error_code,'PRE_DISPATCH_FAILED'),
      COALESCE(p_error_message,'Pre-dispatch failure'),
      j.attempt_count,
      jsonb_build_object('compilation_id',j.compilation_id)
    )
    ON CONFLICT(job_id) DO NOTHING;
  ELSE
    v_backoff:=least(
      sp.max_backoff_seconds,
      sp.base_backoff_seconds*
      (power(2,greatest(j.attempt_count-1,0))::integer)
    );

    UPDATE retail.r1d_dispatch_jobs
    SET status='retry_wait',
        next_attempt_at=now()+make_interval(secs=>v_backoff),
        lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
        last_error_code=p_error_code,
        last_error_message=left(p_error_message,4000),
        updated_at=now()
    WHERE id=j.id;
  END IF;
END $$;

-- ---------- COMPLETE / RETRY / CIRCUIT --------------------------------------
CREATE OR REPLACE FUNCTION retail.r1d_finish_job(
  p_job_id uuid,
  p_lease_token uuid,
  p_success boolean,
  p_actual_cost_usd numeric,
  p_cost_basis text,
  p_error_code text,
  p_error_message text,
  p_metrics jsonb,
  p_exit_code integer,
  p_stdout_tail text,
  p_stderr_tail text,
  p_stdout_sha256 text,
  p_stderr_sha256 text,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  j retail.r1d_dispatch_jobs%ROWTYPE;
  sp retail.r1d_schedule_policies%ROWTYPE;
  v_backoff integer;
BEGIN
  SELECT * INTO j
  FROM retail.r1d_dispatch_jobs
  WHERE id=p_job_id FOR UPDATE;

  IF NOT FOUND
     OR j.status NOT IN('leased','dispatching')
     OR j.lease_token IS DISTINCT FROM p_lease_token THEN
    RAISE EXCEPTION 'Job completion blocked: invalid lease';
  END IF;

  SELECT * INTO sp FROM retail.r1d_schedule_policies
  WHERE id=j.schedule_policy_id;

  UPDATE retail.r1d_dispatch_attempts
  SET completed_at=now(),success=p_success,exit_code=p_exit_code,
      error_code=p_error_code,error_message=p_error_message,
      stdout_tail=left(p_stdout_tail,65536),
      stderr_tail=left(p_stderr_tail,65536),
      stdout_sha256=p_stdout_sha256,stderr_sha256=p_stderr_sha256,
      metrics_json=COALESCE(p_metrics,'{}'::jsonb),
      actual_cost_usd=p_actual_cost_usd,cost_basis=p_cost_basis
  WHERE job_id=p_job_id AND attempt_no=j.attempt_count;

  PERFORM retail.r1d_settle_budget(
    p_job_id,
    COALESCE(p_actual_cost_usd,j.estimated_cost_usd),
    COALESCE(p_cost_basis,'estimated'),
    p_process_run_id,p_correlation_id
  );

  IF p_success THEN
    UPDATE retail.r1d_dispatch_jobs
    SET status='succeeded',
        lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
        last_error_code=NULL,last_error_message=NULL,updated_at=now()
    WHERE id=p_job_id;

    UPDATE retail.r1d_compilation_schedule_state
    SET last_succeeded_at=now(),consecutive_failures=0,updated_at=now()
    WHERE compilation_id=j.compilation_id;

    INSERT INTO retail.r1d_circuit_breakers(
      platform_id,collection_source_id,state,consecutive_failures,
      last_success_at
    )
    VALUES(j.platform_id,j.collection_source_id,'closed',0,now())
    ON CONFLICT(platform_id,collection_source_id) DO UPDATE SET
      state='closed',consecutive_failures=0,last_success_at=now(),
      open_until=NULL,updated_at=now();
  ELSE
    v_backoff:=least(
      sp.max_backoff_seconds,
      sp.base_backoff_seconds*
        (power(2,greatest(j.attempt_count-1,0))::integer)
    );

    IF j.attempt_count>=j.max_attempts THEN
      UPDATE retail.r1d_dispatch_jobs
      SET status='dead_letter',
          lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
          last_error_code=p_error_code,
          last_error_message=left(p_error_message,4000),
          updated_at=now()
      WHERE id=p_job_id;

      INSERT INTO retail.r1d_dead_letters(
        job_id,error_code,error_message,attempt_count,payload_snapshot
      )
      SELECT
        j.id,COALESCE(p_error_code,'DISPATCH_FAILED'),
        COALESCE(p_error_message,'Dispatch failed'),
        j.attempt_count,
        jsonb_build_object(
          'compilation_id',j.compilation_id,
          'dispatch_binding_id',j.dispatch_binding_id,
          'route_authority_hash',j.route_authority_hash
        )
      ON CONFLICT(job_id) DO NOTHING;
    ELSE
      UPDATE retail.r1d_dispatch_jobs
      SET status='retry_wait',
          next_attempt_at=now()+make_interval(secs=>v_backoff),
          lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
          last_error_code=p_error_code,
          last_error_message=left(p_error_message,4000),
          updated_at=now()
      WHERE id=p_job_id;
    END IF;

    UPDATE retail.r1d_compilation_schedule_state
    SET consecutive_failures=consecutive_failures+1,updated_at=now()
    WHERE compilation_id=j.compilation_id;

    INSERT INTO retail.r1d_circuit_breakers(
      platform_id,collection_source_id,state,consecutive_failures,
      last_failure_at
    )
    VALUES(j.platform_id,j.collection_source_id,'closed',1,now())
    ON CONFLICT(platform_id,collection_source_id) DO UPDATE SET
      consecutive_failures=retail.r1d_circuit_breakers.consecutive_failures+1,
      last_failure_at=now(),updated_at=now();

    UPDATE retail.r1d_circuit_breakers
    SET state='open',opened_at=now(),
        open_until=now()+make_interval(secs=>open_seconds),
        updated_at=now()
    WHERE platform_id=j.platform_id
      AND collection_source_id IS NOT DISTINCT FROM j.collection_source_id
      AND consecutive_failures>=failure_threshold;
  END IF;
END $$;

-- ---------- LEASE REAPER -----------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1d_reap_expired_leases(
  p_now timestamptz,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  j retail.r1d_dispatch_jobs%ROWTYPE;
  v_count integer:=0;
BEGIN
  FOR j IN
    SELECT * FROM retail.r1d_dispatch_jobs
    WHERE status IN('leased','dispatching')
      AND lease_expires_at<=p_now
    FOR UPDATE SKIP LOCKED
  LOOP
    IF j.status='leased' THEN
      PERFORM retail.r1d_release_budget(
        j.id,p_process_run_id,p_correlation_id
      );
    ELSE
      -- Dispatch may have reached external service; conservatively settle
      -- reserved estimate instead of freeing budget.
      PERFORM retail.r1d_settle_budget(
        j.id,j.estimated_cost_usd,'estimated',
        p_process_run_id,p_correlation_id
      );
    END IF;

    IF j.attempt_count>=j.max_attempts THEN
      UPDATE retail.r1d_dispatch_jobs
      SET status='dead_letter',
          lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
          last_error_code='LEASE_EXPIRED',
          last_error_message='Worker lease expired',
          updated_at=now()
      WHERE id=j.id;

      INSERT INTO retail.r1d_dead_letters(
        job_id,error_code,error_message,attempt_count,payload_snapshot
      )
      VALUES(
        j.id,'LEASE_EXPIRED','Worker lease expired',
        j.attempt_count,
        jsonb_build_object('compilation_id',j.compilation_id)
      )
      ON CONFLICT(job_id) DO NOTHING;
    ELSE
      UPDATE retail.r1d_dispatch_jobs
      SET status='retry_wait',
          next_attempt_at=p_now+interval '60 seconds',
          lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
          last_error_code='LEASE_EXPIRED',
          last_error_message='Worker lease expired',
          updated_at=now()
      WHERE id=j.id;
    END IF;

    v_count:=v_count+1;
  END LOOP;

  RETURN v_count;
END $$;

-- ---------- EFFECTIVE DISPATCH AUTHORITY ------------------------------------
CREATE OR REPLACE VIEW retail.r1d_effective_dispatch_jobs AS
SELECT
  j.*,
  ec.adapter_payload_json,
  ec.normalized_job_json,
  ec.compilation_evidence_json
FROM retail.r1d_dispatch_jobs j
JOIN retail.effective_compiled_search_jobs ec ON ec.id=j.compilation_id
WHERE j.status IN('queued','retry_wait','leased','dispatching')
  AND retail.r1d_r1c_binding_is_current()=true
  AND retail.r1d_dispatch_binding_is_current(j.dispatch_binding_id)=true;

COMMENT ON VIEW retail.r1d_effective_dispatch_jobs IS
'R1D sole runtime dispatch queue. R1D workers must not dispatch directly from R1C compilations.';

-- ---------- CERTIFICATION RUNS ----------------------------------------------
CREATE TABLE retail.r1d_certification_runs(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  certification_version text NOT NULL,
  r1c_certification_run_id uuid NOT NULL REFERENCES retail.r1c_certification_runs(id) ON DELETE RESTRICT,
  r1c_package_sha256 text NOT NULL,
  r1d_package_sha256 text NOT NULL,
  passive_results jsonb NOT NULL DEFAULT '[]'::jsonb,
  active_results jsonb NOT NULL DEFAULT '[]'::jsonb,
  concurrency_results jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence_manifest jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence_manifest_sha256 text NOT NULL,
  total_gates integer NOT NULL,
  passed_gates integer NOT NULL,
  failed_gates integer NOT NULL,
  certification_status text NOT NULL CHECK(certification_status IN('CERTIFIED','FAILED')),
  certified_by text NOT NULL,
  completed_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- AUDIT ------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail_audit.r1d_log_retail_change()
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
    schema_name,table_name,operation,row_pk,old_data,new_data,changed_by
  )
  VALUES(
    TG_TABLE_SCHEMA,TG_TABLE_NAME,TG_OP,COALESCE(v_row->>'id',v_row->>'compilation_id',''),
    CASE WHEN TG_OP IN('UPDATE','DELETE') THEN to_jsonb(OLD) END,
    CASE WHEN TG_OP IN('INSERT','UPDATE') THEN to_jsonb(NEW) END,
    v_actor
  );

  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER trg_r1d_audit_binding
AFTER INSERT OR UPDATE OR DELETE ON retail.r1d_r1c_certification_binding
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1d_log_retail_change();

CREATE TRIGGER trg_r1d_audit_dispatch_binding
AFTER INSERT OR UPDATE OR DELETE ON retail.r1d_dispatch_bindings
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1d_log_retail_change();

CREATE TRIGGER trg_r1d_audit_jobs
AFTER INSERT OR UPDATE OR DELETE ON retail.r1d_dispatch_jobs
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1d_log_retail_change();

CREATE TRIGGER trg_r1d_audit_schedule_state
AFTER INSERT OR UPDATE OR DELETE ON retail.r1d_compilation_schedule_state
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1d_log_retail_change();


CREATE TRIGGER trg_r1d_audit_cost_profiles
AFTER INSERT OR UPDATE OR DELETE ON retail.r1d_cost_profiles
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1d_log_retail_change();

CREATE TRIGGER trg_r1d_audit_budget_policies
AFTER INSERT OR UPDATE OR DELETE ON retail.r1d_budget_policies
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1d_log_retail_change();

CREATE TRIGGER trg_r1d_audit_schedule_policies
AFTER INSERT OR UPDATE OR DELETE ON retail.r1d_schedule_policies
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1d_log_retail_change();

CREATE TRIGGER trg_r1d_audit_geo_events
AFTER INSERT OR UPDATE OR DELETE ON retail.r1d_geo_activation_events
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1d_log_retail_change();

-- ---------- PUBLIC PRIVILEGE HARDENING --------------------------------------
REVOKE ALL ON FUNCTION retail.r1d_bind_r1c_certification(uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_sync_schedule_state(timestamptz,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_set_geo_activation(uuid,text,text,numeric,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_activate_geo_children(uuid,text,numeric,text,integer,text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_materialize_due_jobs(timestamptz,integer,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_claim_next_job(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_mark_dispatching(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_finish_job(uuid,uuid,boolean,numeric,text,text,text,jsonb,integer,text,text,text,text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_reap_expired_leases(timestamptz,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_register_dispatch_binding(uuid,text,text,text,integer,integer,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_certify_dispatch_binding(uuid,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_fail_pre_dispatch(uuid,uuid,text,text,boolean,uuid,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION retail.r1d_sync_schedule_state(timestamptz,uuid,text)
  TO retail_r1d_scheduler;
GRANT EXECUTE ON FUNCTION retail.r1d_set_geo_activation(uuid,text,text,numeric,text)
  TO retail_r1d_scheduler;
GRANT EXECUTE ON FUNCTION retail.r1d_activate_geo_children(uuid,text,numeric,text,integer,text,uuid,text)
  TO retail_r1d_scheduler;
GRANT EXECUTE ON FUNCTION retail.r1d_materialize_due_jobs(timestamptz,integer,uuid,text,text)
  TO retail_r1d_scheduler;
GRANT EXECUTE ON FUNCTION retail.r1d_claim_next_job(text,uuid,text)
  TO retail_r1d_dispatcher;
GRANT EXECUTE ON FUNCTION retail.r1d_fail_pre_dispatch(uuid,uuid,text,text,boolean,uuid,text)
  TO retail_r1d_dispatcher;
GRANT EXECUTE ON FUNCTION retail.r1d_mark_dispatching(uuid,uuid)
  TO retail_r1d_dispatcher;
GRANT EXECUTE ON FUNCTION retail.r1d_finish_job(uuid,uuid,boolean,numeric,text,text,text,jsonb,integer,text,text,text,text,uuid,text)
  TO retail_r1d_dispatcher;
GRANT EXECUTE ON FUNCTION retail.r1d_reap_expired_leases(timestamptz,uuid,text)
  TO retail_r1d_dispatcher;
GRANT EXECUTE ON FUNCTION retail.r1d_bind_r1c_certification(uuid,uuid,text,text)
  TO retail_r1d_certifier;
GRANT EXECUTE ON FUNCTION retail.r1d_register_dispatch_binding(uuid,text,text,text,integer,integer,jsonb,text)
  TO retail_r1d_certifier;
GRANT EXECUTE ON FUNCTION retail.r1d_certify_dispatch_binding(uuid,jsonb,text)
  TO retail_r1d_certifier;

GRANT SELECT ON retail.r1d_effective_dispatch_jobs TO retail_r1d_reader;
GRANT SELECT ON retail.r1d_dispatch_jobs TO retail_r1d_reader;
GRANT SELECT ON retail.r1d_budget_reservations TO retail_r1d_reader;
GRANT SELECT ON retail.r1d_dispatch_attempts TO retail_r1d_reader;

REVOKE INSERT,UPDATE,DELETE ON retail.r1d_r1c_certification_binding FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE ON retail.r1d_dispatch_bindings FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE ON retail.r1d_dispatch_jobs FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE ON retail.r1d_budget_reservations FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE ON retail.r1d_budget_ledger FROM PUBLIC;

COMMIT;
