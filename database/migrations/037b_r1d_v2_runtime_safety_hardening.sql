BEGIN;

-- ============================================================================
-- TCDS RETAIL R1D V2 — RUNTIME SAFETY & DISPATCH AUTHORITY HARDENED FINAL
-- Additive hardening over 037_r1d_scheduler_dispatcher.sql
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('retail.r1d_schema_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1d_schema_state
       WHERE singleton=true AND schema_version='1.0.0'
     ) THEN
    RAISE EXCEPTION 'R1D V2 requires installed R1D V1 schema 1.0.0';
  END IF;

  IF to_regclass('retail.r1c_v3_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1c_v3_state
       WHERE singleton=true AND hardening_version='3.0.0'
     ) THEN
    RAISE EXCEPTION 'R1D V2 requires installed R1C V3 hardening 3.0.0';
  END IF;

  IF NOT EXISTS(
    SELECT 1
    FROM retail.r1c_certification_runs
    WHERE id=(
      SELECT id FROM retail.r1c_certification_runs
      WHERE completed_at IS NOT NULL
      ORDER BY completed_at DESC,id::text DESC
      LIMIT 1
    )
      AND certification_version='r1c-v3.0.0'
      AND certification_status='CERTIFIED'
  ) THEN
    RAISE EXCEPTION 'R1D V2 requires latest R1C certification = r1c-v3.0.0 CERTIFIED';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS retail.r1d_v2_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  hardening_version text NOT NULL,
  doctrine text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user
);

INSERT INTO retail.r1d_v2_state(singleton,hardening_version,doctrine)
VALUES(
  true,'2.0.0',
  'R1D V2 enforces maximum-cost reservation, attempt-scoped external/rate authority, stale-job reconciliation, atomic half-open circuits, explicit execution command/interpreter authority, persistent workers, reproducible certification evidence, and append-only certification history.'
)
ON CONFLICT(singleton) DO UPDATE SET
  hardening_version=EXCLUDED.hardening_version,
  doctrine=EXCLUDED.doctrine;

-- ---------- GOVERNANCE PROCESSES --------------------------------------------
INSERT INTO arb.process_registry(
  process_name,phase_no,process_group,description,owner_team,active_flag
)
VALUES
('RETAIL_R1D_STALE_RECONCILE',2,'RETAIL_AUTOMATION',
 'Cancel stale queued/retry jobs whose R1C or dispatch authority is no longer current.',
 'TCDS Retail Automation',true),
('RETAIL_R1D_CERT_FIXTURE_PREP',2,'RETAIL_AUTOMATION',
 'Create isolated R1D QA concurrency fixtures that cannot consume production queue entries.',
 'TCDS Retail Automation',true),
('RETAIL_R1D_RATE_POLICY_CONFIG',2,'RETAIL_AUTOMATION',
 'Create immutable explicit platform request-rate policies.',
 'TCDS Retail Automation',true)
ON CONFLICT(process_name) DO NOTHING;

-- ---------- AUDIT CONTEXT ----------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1d_set_audit_context(
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  r record;
BEGIN
  SELECT actor_type,actor_id,actor_name
  INTO r
  FROM arb.process_runs
  WHERE run_id=p_process_run_id;

  IF FOUND THEN
    PERFORM set_config('app.actor_type',COALESCE(r.actor_type,'system'),true);
    PERFORM set_config('app.actor_id',COALESCE(r.actor_id,'unknown'),true);
    PERFORM set_config('app.actor_name',COALESCE(r.actor_name,r.actor_id,'unknown'),true);
    PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  END IF;
  IF p_correlation_id IS NOT NULL THEN
    PERFORM set_config('app.correlation_id',p_correlation_id,true);
  END IF;
END $$;

-- ---------- ABSOLUTE COST GOVERNOR ------------------------------------------
ALTER TABLE retail.r1d_cost_profiles
  ADD COLUMN IF NOT EXISTS cost_model_json jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK(jsonb_typeof(cost_model_json)='object'),
  ADD COLUMN IF NOT EXISTS max_execution_cost_usd numeric
    CHECK(max_execution_cost_usd IS NULL OR max_execution_cost_usd>=0),
  ADD COLUMN IF NOT EXISTS violation_status text NOT NULL DEFAULT 'clear'
    CHECK(violation_status IN('clear','violated','suspended')),
  ADD COLUMN IF NOT EXISTS violation_reason text;

CREATE TABLE IF NOT EXISTS retail.r1d_cost_model_violations(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job_id uuid NOT NULL REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  cost_profile_id uuid NOT NULL REFERENCES retail.r1d_cost_profiles(id) ON DELETE RESTRICT,
  reserved_max_usd numeric NOT NULL,
  observed_actual_usd numeric NOT NULL,
  violation_code text NOT NULL,
  process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  correlation_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);


CREATE OR REPLACE FUNCTION retail.r1d_active_policy_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_old jsonb;
  v_new jsonb;
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1D policy rows cannot be deleted; deactivate them';
  END IF;

  IF TG_TABLE_NAME='r1d_cost_profiles' THEN
    v_old:=to_jsonb(OLD)-ARRAY[
      'active','updated_at','violation_status','violation_reason'
    ];
    v_new:=to_jsonb(NEW)-ARRAY[
      'active','updated_at','violation_status','violation_reason'
    ];
  ELSE
    v_old:=to_jsonb(OLD)-ARRAY['active','updated_at'];
    v_new:=to_jsonb(NEW)-ARRAY['active','updated_at'];
  END IF;

  IF OLD.active=true AND v_new IS DISTINCT FROM v_old THEN
    RAISE EXCEPTION 'Active R1D policy is immutable; deactivate and create new version';
  END IF;

  IF OLD.active=false AND NEW.active<>OLD.active THEN
    RAISE EXCEPTION 'Inactive R1D policy cannot be reactivated; create a new version';
  END IF;

  NEW.updated_at:=now();
  RETURN NEW;
END $$;

-- Cost model supports bounded multi-stage collectors.
-- Example:
-- {
--   "fixed_usd": 0.01,
--   "components":[
--     {"name":"discovery","max_units":2,"unit_cost_usd":0.001},
--     {"name":"pdp_records","max_units_source":"target.discovery_result_limit","unit_cost_usd":0.0015}
--   ],
--   "retry_allowance_multiplier":1.20
-- }
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
  v_component jsonb;
  v_units numeric;
  v_cost numeric:=0;
  v_multiplier numeric:=1;
BEGIN
  SELECT * INTO j
  FROM retail.effective_compiled_search_jobs
  WHERE id=p_compilation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Compilation not effective'; END IF;

  SELECT * INTO c
  FROM retail.r1d_cost_profiles
  WHERE id=p_cost_profile_id
    AND active=true
    AND violation_status='clear';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active non-violated cost profile required';
  END IF;

  IF c.max_execution_cost_usd IS NULL THEN
    RAISE EXCEPTION 'Cost profile must define certified max_execution_cost_usd';
  END IF;

  IF jsonb_array_length(COALESCE(c.cost_model_json->'components','[]'::jsonb))>0 THEN
    v_cost:=COALESCE((c.cost_model_json->>'fixed_usd')::numeric,0);
    FOR v_component IN
      SELECT value
      FROM jsonb_array_elements(c.cost_model_json->'components')
    LOOP
      IF v_component ? 'max_units' THEN
        v_units:=(v_component->>'max_units')::numeric;
      ELSIF v_component->>'max_units_source'='target.discovery_result_limit' THEN
        v_units:=COALESCE(
          nullif(j.normalized_job_json#>>'{target,discovery_result_limit}','')::numeric,
          1
        );
      ELSE
        RAISE EXCEPTION 'Unsupported cost-model max_units_source';
      END IF;

      IF v_units<0 OR COALESCE((v_component->>'unit_cost_usd')::numeric,-1)<0 THEN
        RAISE EXCEPTION 'Invalid cost-model component';
      END IF;
      v_cost:=v_cost+(v_units*(v_component->>'unit_cost_usd')::numeric);
    END LOOP;
    v_multiplier:=COALESCE(
      (c.cost_model_json->>'retry_allowance_multiplier')::numeric,
      c.safety_multiplier,
      1
    );
    IF v_multiplier<1 OR v_multiplier>10 THEN
      RAISE EXCEPTION 'Invalid retry_allowance_multiplier';
    END IF;
    v_cost:=v_cost*v_multiplier;
  ELSE
    -- Backward-compatible bounded V1 model.
    v_units:=CASE
      WHEN c.unit_type='per_record' THEN COALESCE(
        nullif(j.normalized_job_json#>>'{target,discovery_result_limit}','')::numeric,1
      )
      ELSE 1
    END;
    v_cost:=(c.fixed_cost_usd+c.unit_cost_usd*v_units)*c.safety_multiplier;
  END IF;

  IF v_cost>c.max_execution_cost_usd THEN
    RAISE EXCEPTION
      'Calculated maximum execution cost % exceeds certified ceiling %',
      v_cost,c.max_execution_cost_usd;
  END IF;

  RETURN round(c.max_execution_cost_usd,6);
END $$;

-- DAILY + MONTHLY budget periods.
ALTER TABLE retail.r1d_budget_policies
  ADD COLUMN IF NOT EXISTS period_kind text NOT NULL DEFAULT 'DAILY'
    CHECK(period_kind IN('DAILY','MONTHLY'));

DROP INDEX IF EXISTS retail.uq_r1d_one_active_global_budget;
DROP INDEX IF EXISTS retail.uq_r1d_one_active_platform_budget;
DROP INDEX IF EXISTS retail.uq_r1d_one_active_source_budget;

CREATE UNIQUE INDEX uq_r1d_one_active_global_budget_period
ON retail.r1d_budget_policies(scope_type,period_kind)
WHERE active AND scope_type='GLOBAL';

CREATE UNIQUE INDEX uq_r1d_one_active_platform_budget_period
ON retail.r1d_budget_policies(platform_id,period_kind)
WHERE active AND scope_type='PLATFORM';

CREATE UNIQUE INDEX uq_r1d_one_active_source_budget_period
ON retail.r1d_budget_policies(collection_source_id,period_kind)
WHERE active AND scope_type='SOURCE';

ALTER TABLE retail.r1d_budget_reservations
  ADD COLUMN IF NOT EXISTS budget_period_kind text NOT NULL DEFAULT 'DAILY'
    CHECK(budget_period_kind IN('DAILY','MONTHLY')),
  ADD COLUMN IF NOT EXISTS budget_period_start date;

UPDATE retail.r1d_budget_reservations
SET budget_period_start=COALESCE(budget_period_start,budget_day)
WHERE budget_period_start IS NULL;

ALTER TABLE retail.r1d_budget_reservations
  ALTER COLUMN budget_period_start SET NOT NULL;

CREATE OR REPLACE FUNCTION retail.r1d_budget_period_start(
  p_period_kind text,
  p_now timestamptz
)
RETURNS date
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE p_period_kind
    WHEN 'DAILY' THEN (p_now AT TIME ZONE 'UTC')::date
    WHEN 'MONTHLY' THEN date_trunc('month',p_now AT TIME ZONE 'UTC')::date
    ELSE NULL
  END
$$;

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
  v_period_start date;
  v_used numeric;
  v_global_daily integer:=0;
  v_global_monthly integer:=0;
  v_count integer:=0;
BEGIN
  PERFORM retail.r1d_set_audit_context(p_process_run_id,p_correlation_id);

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

  UPDATE retail.r1d_dispatch_jobs
  SET budget_reservation_group=NULL,updated_at=now()
  WHERE id=j.id AND budget_reservation_group IS NOT NULL;

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
    ORDER BY scope_type,period_kind,id
    FOR UPDATE
  LOOP
    v_period_start:=retail.r1d_budget_period_start(p.period_kind,now());

    IF p.scope_type='GLOBAL' AND p.period_kind='DAILY' THEN
      v_global_daily:=v_global_daily+1;
    ELSIF p.scope_type='GLOBAL' AND p.period_kind='MONTHLY' THEN
      v_global_monthly:=v_global_monthly+1;
    END IF;

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
      AND budget_period_start=v_period_start
      AND budget_period_kind=p.period_kind;

    IF v_used+j.estimated_cost_usd>p.daily_limit_usd THEN
      RETURN NULL;
    END IF;
    v_count:=v_count+1;
  END LOOP;

  IF v_global_daily<>1 OR v_global_monthly<>1 THEN
    RAISE EXCEPTION
      'R1D fail-closed: exactly one active GLOBAL DAILY and MONTHLY budget required';
  END IF;
  IF v_count<2 THEN
    RAISE EXCEPTION 'No applicable budget policies';
  END IF;

  INSERT INTO retail.r1d_budget_reservations(
    reservation_group,job_id,budget_policy_id,budget_day,
    budget_period_kind,budget_period_start,reserved_usd,status
  )
  SELECT
    v_group,j.id,p.id,
    (now() AT TIME ZONE 'UTC')::date,
    p.period_kind,
    retail.r1d_budget_period_start(p.period_kind,now()),
    j.estimated_cost_usd,'reserved'
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
  SELECT reservation_group,job_id,budget_policy_id,'RESERVE',
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
  j record;
  v_reserved_max numeric;
  v_profile uuid;
BEGIN
  PERFORM retail.r1d_set_audit_context(p_process_run_id,p_correlation_id);

  IF p_actual_cost_usd IS NULL OR p_actual_cost_usd<0 THEN
    RAISE EXCEPTION 'Actual cost must be nonnegative';
  END IF;
  IF p_cost_basis NOT IN('actual','estimated') THEN
    RAISE EXCEPTION 'cost_basis must be actual/estimated';
  END IF;

  SELECT cost_profile_id INTO v_profile
  FROM retail.r1d_dispatch_jobs
  WHERE id=p_job_id;

  SELECT max(reserved_usd)
  INTO v_reserved_max
  FROM retail.r1d_budget_reservations
  WHERE job_id=p_job_id AND status='reserved';

  IF v_reserved_max IS NULL THEN RETURN; END IF;

  IF p_actual_cost_usd>v_reserved_max THEN
    INSERT INTO retail.r1d_cost_model_violations(
      job_id,cost_profile_id,reserved_max_usd,observed_actual_usd,
      violation_code,process_run_id,correlation_id
    )
    VALUES(
      p_job_id,v_profile,v_reserved_max,p_actual_cost_usd,
      'ACTUAL_EXCEEDS_RESERVED_MAX',p_process_run_id,p_correlation_id
    );

    UPDATE retail.r1d_cost_profiles
    SET active=false,
        violation_status='suspended',
        violation_reason='Observed actual cost exceeded certified maximum reservation',
        updated_at=now()
    WHERE id=v_profile;

    -- Preserve actual billing truth, but the incident permanently removes
    -- this cost profile from future execution until a new version is certified.
  END IF;

  UPDATE retail.r1d_budget_reservations
  SET actual_usd=p_actual_cost_usd,status='settled',
      cost_basis=p_cost_basis,settled_at=now()
  WHERE job_id=p_job_id AND status='reserved';

  INSERT INTO retail.r1d_budget_ledger(
    reservation_group,job_id,budget_policy_id,event_type,
    amount_usd,process_run_id,correlation_id
  )
  SELECT reservation_group,job_id,budget_policy_id,'SETTLE',
         p_actual_cost_usd,p_process_run_id,p_correlation_id
  FROM retail.r1d_budget_reservations
  WHERE job_id=p_job_id
    AND status='settled'
    AND settled_at>=now()-interval '5 seconds';

  UPDATE retail.r1d_dispatch_jobs
  SET budget_reservation_group=NULL,updated_at=now()
  WHERE id=p_job_id;
END $$;

-- ---------- EXPLICIT RATE POLICY / ATTEMPT RESERVATIONS ---------------------
CREATE TABLE IF NOT EXISTS retail.r1d_rate_policies(
  platform_id uuid PRIMARY KEY REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  hourly_limit integer CHECK(hourly_limit IS NULL OR hourly_limit>0),
  daily_limit integer CHECK(daily_limit IS NULL OR daily_limit>0),
  hourly_unlimited boolean NOT NULL DEFAULT false,
  daily_unlimited boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK((hourly_limit IS NOT NULL) <> hourly_unlimited),
  CHECK((daily_limit IS NOT NULL) <> daily_unlimited)
);

CREATE TABLE IF NOT EXISTS retail.r1d_rate_reservations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  attempt_no integer NOT NULL,
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  hour_bucket timestamptz NOT NULL,
  day_bucket date NOT NULL,
  status text NOT NULL CHECK(status IN('reserved','consumed','released')),
  created_at timestamptz NOT NULL DEFAULT now(),
  consumed_at timestamptz,
  released_at timestamptz,
  UNIQUE(job_id,attempt_no)
);

CREATE OR REPLACE FUNCTION retail.r1d_reserve_rate_slot_v2(
  p_job_id uuid,
  p_attempt_no integer,
  p_now timestamptz
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  j retail.r1d_dispatch_jobs%ROWTYPE;
  p retail.r1d_rate_policies%ROWTYPE;
  v_hour timestamptz:=date_trunc('hour',p_now);
  v_day date:=(p_now AT TIME ZONE 'UTC')::date;
  v_hour_used integer;
  v_day_used integer;
  v_id uuid;
BEGIN
  SELECT * INTO j FROM retail.r1d_dispatch_jobs
  WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Rate reservation job missing'; END IF;

  SELECT * INTO p FROM retail.r1d_rate_policies
  WHERE platform_id=j.platform_id AND active=true
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1D fail-closed: explicit active rate policy required';
  END IF;

  SELECT count(*)::int INTO v_hour_used
  FROM retail.r1d_rate_reservations
  WHERE platform_id=j.platform_id
    AND hour_bucket=v_hour
    AND status IN('reserved','consumed');

  SELECT count(*)::int INTO v_day_used
  FROM retail.r1d_rate_reservations
  WHERE platform_id=j.platform_id
    AND day_bucket=v_day
    AND status IN('reserved','consumed');

  IF (NOT p.hourly_unlimited AND v_hour_used>=p.hourly_limit)
     OR (NOT p.daily_unlimited AND v_day_used>=p.daily_limit) THEN
    RETURN NULL;
  END IF;

  INSERT INTO retail.r1d_rate_reservations(
    job_id,attempt_no,platform_id,hour_bucket,day_bucket,status
  )
  VALUES(j.id,p_attempt_no,j.platform_id,v_hour,v_day,'reserved')
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION retail.r1d_consume_rate_slot(
  p_job_id uuid,
  p_attempt_no integer
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  UPDATE retail.r1d_rate_reservations
  SET status='consumed',consumed_at=now()
  WHERE job_id=p_job_id
    AND attempt_no=p_attempt_no
    AND status='reserved'
$$;

CREATE OR REPLACE FUNCTION retail.r1d_release_rate_slot(
  p_job_id uuid,
  p_attempt_no integer
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  UPDATE retail.r1d_rate_reservations
  SET status='released',released_at=now()
  WHERE job_id=p_job_id
    AND attempt_no=p_attempt_no
    AND status='reserved'
$$;


-- V2 runtime adds circuit_permit_token. Keep authority fields immutable while
-- explicitly allowing runtime lease/circuit state transitions.
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
        'budget_reservation_group','circuit_permit_token',
        'last_error_code','last_error_message','updated_at'
      ])
     IS DISTINCT FROM
     (to_jsonb(OLD)-ARRAY[
        'status','attempt_count','next_attempt_at',
        'lease_token','leased_by','leased_at','lease_expires_at',
        'budget_reservation_group','circuit_permit_token',
        'last_error_code','last_error_message','updated_at'
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

-- ---------- TRUE HALF-OPEN CIRCUIT PERMITS ----------------------------------
ALTER TABLE retail.r1d_circuit_breakers
  ADD COLUMN IF NOT EXISTS half_open_token uuid,
  ADD COLUMN IF NOT EXISTS half_open_expires_at timestamptz;

ALTER TABLE retail.r1d_dispatch_jobs
  ADD COLUMN IF NOT EXISTS circuit_permit_token uuid,
  ADD COLUMN IF NOT EXISTS certification_fixture boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION retail.r1d_acquire_circuit_permit(
  p_platform_id uuid,
  p_source_id uuid,
  p_now timestamptz
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  b retail.r1d_circuit_breakers%ROWTYPE;
  v_token uuid:=gen_random_uuid();
BEGIN
  INSERT INTO retail.r1d_circuit_breakers(
    platform_id,collection_source_id,state,consecutive_failures
  )
  VALUES(p_platform_id,p_source_id,'closed',0)
  ON CONFLICT(platform_id,collection_source_id) DO NOTHING;

  SELECT * INTO b
  FROM retail.r1d_circuit_breakers
  WHERE platform_id=p_platform_id
    AND collection_source_id IS NOT DISTINCT FROM p_source_id
  FOR UPDATE;

  IF b.state='closed' THEN
    RETURN v_token;
  END IF;

  IF b.state='open' THEN
    IF b.open_until IS NULL OR b.open_until>p_now THEN
      RETURN NULL;
    END IF;

    UPDATE retail.r1d_circuit_breakers
    SET state='half_open',
        half_open_token=v_token,
        half_open_expires_at=p_now+interval '5 minutes',
        updated_at=now()
    WHERE platform_id=p_platform_id
      AND collection_source_id IS NOT DISTINCT FROM p_source_id;
    RETURN v_token;
  END IF;

  IF b.state='half_open' THEN
    IF b.half_open_expires_at<=p_now THEN
      UPDATE retail.r1d_circuit_breakers
      SET half_open_token=v_token,
          half_open_expires_at=p_now+interval '5 minutes',
          updated_at=now()
      WHERE platform_id=p_platform_id
        AND collection_source_id IS NOT DISTINCT FROM p_source_id;
      RETURN v_token;
    END IF;
    RETURN NULL;
  END IF;

  RETURN NULL;
END $$;


CREATE OR REPLACE FUNCTION retail.r1d_release_circuit_permit(
  p_platform_id uuid,
  p_source_id uuid,
  p_permit_token uuid
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  b retail.r1d_circuit_breakers%ROWTYPE;
BEGIN
  SELECT * INTO b
  FROM retail.r1d_circuit_breakers
  WHERE platform_id=p_platform_id
    AND collection_source_id IS NOT DISTINCT FROM p_source_id
  FOR UPDATE;

  IF NOT FOUND THEN RETURN; END IF;

  -- Closed-state permits are ephemeral and require no state mutation.
  IF b.state='closed' THEN
    RETURN;
  END IF;

  -- A half-open permit that never reached the retailer is not a successful
  -- recovery probe. Re-open the breaker for another cooldown window.
  IF b.state='half_open'
     AND b.half_open_token IS NOT DISTINCT FROM p_permit_token THEN
    UPDATE retail.r1d_circuit_breakers
    SET state='open',
        opened_at=COALESCE(opened_at,now()),
        open_until=now()+make_interval(secs=>open_seconds),
        half_open_token=NULL,
        half_open_expires_at=NULL,
        updated_at=now()
    WHERE platform_id=p_platform_id
      AND collection_source_id IS NOT DISTINCT FROM p_source_id;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION retail.r1d_complete_circuit_permit(
  p_platform_id uuid,
  p_source_id uuid,
  p_permit_token uuid,
  p_success boolean
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  b retail.r1d_circuit_breakers%ROWTYPE;
BEGIN
  SELECT * INTO b
  FROM retail.r1d_circuit_breakers
  WHERE platform_id=p_platform_id
    AND collection_source_id IS NOT DISTINCT FROM p_source_id
  FOR UPDATE;

  IF NOT FOUND THEN RETURN; END IF;

  IF p_success THEN
    UPDATE retail.r1d_circuit_breakers
    SET state='closed',consecutive_failures=0,
        last_success_at=now(),opened_at=NULL,open_until=NULL,
        half_open_token=NULL,half_open_expires_at=NULL,
        updated_at=now()
    WHERE platform_id=p_platform_id
      AND collection_source_id IS NOT DISTINCT FROM p_source_id
      AND (
        state='closed'
        OR (state='half_open' AND half_open_token=p_permit_token)
      );
  ELSE
    UPDATE retail.r1d_circuit_breakers
    SET consecutive_failures=consecutive_failures+1,
        last_failure_at=now(),
        state=CASE
          WHEN state='half_open'
            OR consecutive_failures+1>=failure_threshold
          THEN 'open' ELSE 'closed' END,
        opened_at=CASE
          WHEN state='half_open'
            OR consecutive_failures+1>=failure_threshold
          THEN now() ELSE opened_at END,
        open_until=CASE
          WHEN state='half_open'
            OR consecutive_failures+1>=failure_threshold
          THEN now()+make_interval(secs=>open_seconds)
          ELSE open_until END,
        half_open_token=NULL,half_open_expires_at=NULL,
        updated_at=now()
    WHERE platform_id=p_platform_id
      AND collection_source_id IS NOT DISTINCT FROM p_source_id
      AND (state<>'half_open' OR half_open_token=p_permit_token);
  END IF;
END $$;

-- ---------- ATTEMPT-SCOPED OUTBOX -------------------------------------------
ALTER TABLE retail.r1d_dispatch_outbox
  DROP CONSTRAINT IF EXISTS r1d_dispatch_outbox_job_id_key;

ALTER TABLE retail.r1d_dispatch_outbox
  ADD COLUMN IF NOT EXISTS attempt_no integer,
  ADD COLUMN IF NOT EXISTS outbox_message_id uuid NOT NULL DEFAULT gen_random_uuid();

UPDATE retail.r1d_dispatch_outbox o
SET attempt_no=COALESCE(
  attempt_no,
  (SELECT max(a.attempt_no) FROM retail.r1d_dispatch_attempts a WHERE a.job_id=o.job_id),
  1
)
WHERE attempt_no IS NULL;

ALTER TABLE retail.r1d_dispatch_outbox
  ALTER COLUMN attempt_no SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_r1d_outbox_job_attempt
ON retail.r1d_dispatch_outbox(job_id,attempt_no);

CREATE UNIQUE INDEX IF NOT EXISTS uq_r1d_outbox_message
ON retail.r1d_dispatch_outbox(outbox_message_id);

-- ---------- STALE JOB RECONCILIATION ----------------------------------------
CREATE OR REPLACE FUNCTION retail.r1d_reconcile_stale_jobs(
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
  PERFORM retail.r1d_set_audit_context(p_process_run_id,p_correlation_id);

  FOR j IN
    SELECT q.*
    FROM retail.r1d_dispatch_jobs q
    WHERE q.status IN('queued','retry_wait')
      AND (
        NOT EXISTS(
          SELECT 1
          FROM retail.effective_compiled_search_jobs ec
          WHERE ec.id=q.compilation_id
            AND ec.route_authority_hash=q.route_authority_hash
            AND ec.adapter_payload_sha256=q.adapter_payload_sha256
            AND ec.compiler_authority_sha256=q.compiler_authority_sha256
        )
        OR retail.r1d_dispatch_binding_is_current(q.dispatch_binding_id) IS NOT TRUE
        OR NOT EXISTS(
          SELECT 1 FROM retail.r1d_cost_profiles cp
          WHERE cp.id=q.cost_profile_id
            AND cp.active=true
            AND cp.violation_status='clear'
        )
        OR NOT EXISTS(
          SELECT 1 FROM retail.r1d_schedule_policies sp
          WHERE sp.id=q.schedule_policy_id AND sp.active=true
        )
        OR NOT EXISTS(
          SELECT 1 FROM retail.r1d_rate_policies rp
          WHERE rp.platform_id=q.platform_id AND rp.active=true
        )
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    PERFORM retail.r1d_release_budget(j.id,p_process_run_id,p_correlation_id);

    UPDATE retail.r1d_rate_reservations
    SET status='released',released_at=now()
    WHERE job_id=j.id AND status='reserved';

    UPDATE retail.r1d_dispatch_jobs
    SET status='cancelled',
        last_error_code='STALE_EXECUTION_AUTHORITY',
        last_error_message='R1C compilation or R1D dispatch authority is no longer current',
        updated_at=now()
    WHERE id=j.id;

    v_count:=v_count+1;
  END LOOP;

  RETURN v_count;
END $$;

-- ---------- EXECUTION COMMAND / RUNNER AUTHORITY ----------------------------
UPDATE retail.r1d_dispatch_bindings
SET certification_status='suspended',updated_at=now()
WHERE runner_kind='node_file'
  AND certification_status='certified';

ALTER TABLE retail.r1d_dispatch_bindings
  DROP CONSTRAINT IF EXISTS r1d_dispatch_bindings_runner_kind_check;

ALTER TABLE retail.r1d_dispatch_bindings
  ADD CONSTRAINT r1d_dispatch_bindings_runner_kind_check
  CHECK(runner_kind IN('node_file','node_js','tsx_file','npm_script','external_queue'));

CREATE UNIQUE INDEX IF NOT EXISTS uq_r1d_one_certified_binding_per_adapter
ON retail.r1d_dispatch_bindings(adapter_id)
WHERE certification_status='certified';

CREATE OR REPLACE FUNCTION retail.r1d_validate_runner_policy(p_policy jsonb)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  k text;
BEGIN
  IF p_policy IS NULL OR jsonb_typeof(p_policy)<>'object' THEN
    RAISE EXCEPTION 'runner_policy_json must be an object';
  END IF;

  FOR k IN SELECT key FROM jsonb_each(p_policy)
  LOOP
    IF k NOT IN('inherited_env_allowlist','graceful_kill_seconds') THEN
      RAISE EXCEPTION 'Unsupported runner_policy_json field %',k;
    END IF;
  END LOOP;

  IF p_policy ? 'inherited_env_allowlist'
     AND jsonb_typeof(p_policy->'inherited_env_allowlist')<>'array' THEN
    RAISE EXCEPTION 'inherited_env_allowlist must be array';
  END IF;

  IF p_policy ? 'graceful_kill_seconds'
     AND (
       (p_policy->>'graceful_kill_seconds')::integer<1
       OR (p_policy->>'graceful_kill_seconds')::integer>60
     ) THEN
    RAISE EXCEPTION 'graceful_kill_seconds must be 1..60';
  END IF;
END $$;



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
  IF NOT FOUND THEN RAISE EXCEPTION 'Execution-ready R1B adapter required'; END IF;

  IF p_runner_kind NOT IN('node_js','tsx_file','npm_script','external_queue') THEN
    RAISE EXCEPTION 'Unsupported R1D V2 runner_kind';
  END IF;
  IF p_payload_delivery NOT IN('env','argv','stdin_json','env_plus_stdin_json') THEN
    RAISE EXCEPTION 'Unsupported payload_delivery';
  END IF;

  PERFORM retail.r1d_validate_runner_policy(COALESCE(p_runner_policy,'{}'::jsonb));

  SELECT COALESCE(max(binding_version),0)+1 INTO v_version
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
    p_timeout_seconds,p_max_concurrency,COALESCE(p_runner_policy,'{}'::jsonb),
    '{}'::jsonb,repeat('0',64),'draft','{}'::jsonb,repeat('0',64),p_actor
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION retail.r1d_dispatch_binding_is_current(p_binding_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      b.certification_status='certified'
      AND b.runner_kind IN('node_js','tsx_file','npm_script','external_queue')
      AND b.binding_sha256=
          retail.r1d_sha256_jsonb(retail.r1d_dispatch_binding_document(b))
      AND b.certification_evidence_json<>'{}'::jsonb
      AND b.certification_evidence_sha256=
          retail.r1d_sha256_jsonb(b.certification_evidence_json)
      AND a.scraper_asset_id=b.scraper_asset_id
      AND a.scraper_contract_id=b.scraper_contract_id
      AND retail.r1b_adapter_execution_ready(a.id)=true
      AND s.discovery_status='verified'
      AND c.certification_status='certified_for_r1'
      AND c.contract_sha256=retail.r1b_sha256_jsonb(c.contract_document)
      AND (
        (b.runner_kind='node_js'
          AND s.implementation_authority_type='file'
          AND s.entrypoint_ref ~ '\.(js|mjs|cjs)$')
        OR
        (b.runner_kind='tsx_file'
          AND s.implementation_authority_type='file'
          AND s.entrypoint_ref ~ '\.tsx?$')
        OR
        (b.runner_kind='npm_script'
          AND s.implementation_authority_type='package_tree'
          AND s.execution_command='npm run '||b.npm_script)
        OR b.runner_kind='external_queue'
      )
    FROM retail.r1d_dispatch_bindings b
    JOIN retail.retail_search_adapters a ON a.id=b.adapter_id
    JOIN retail.retail_scraper_assets s ON s.id=b.scraper_asset_id
    JOIN retail.retail_scraper_contracts c ON c.id=b.scraper_contract_id
    WHERE b.id=p_binding_id
  ),false)
$$;

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
  v_expected_script text;
  v_expected_artifact_sha text;
  v_map_value text;
  v_required_evidence constant text[]:=ARRAY[
    'adapter_id','scraper_asset_id','scraper_contract_id',
    'runner','transport','fixture_payload_sha256',
    'test_result','exit_status','db_ingest_proof',
    'artifact_sha256','qa_actor','qa_at'
  ];
  k text;
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended('r1d-binding:'||p_binding_id::text,0)
  );

  SELECT * INTO b FROM retail.r1d_dispatch_bindings
  WHERE id=p_binding_id FOR UPDATE;
  IF NOT FOUND OR b.certification_status<>'draft' THEN
    RAISE EXCEPTION 'Dispatch binding missing/not eligible';
  END IF;

  -- Serialize certification per adapter.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('r1d-binding-adapter:'||b.adapter_id::text,0)
  );

  IF p_evidence IS NULL OR jsonb_typeof(p_evidence)<>'object'
     OR p_evidence='{}'::jsonb THEN
    RAISE EXCEPTION 'Non-empty certification evidence required';
  END IF;

  FOREACH k IN ARRAY v_required_evidence
  LOOP
    IF NOT (p_evidence ? k) THEN
      RAISE EXCEPTION 'Dispatch-binding evidence missing required field %',k;
    END IF;
  END LOOP;

  SELECT * INTO a FROM retail.retail_search_adapters WHERE id=b.adapter_id;
  SELECT * INTO s FROM retail.retail_scraper_assets WHERE id=b.scraper_asset_id;
  SELECT * INTO c FROM retail.retail_scraper_contracts WHERE id=b.scraper_contract_id;

  IF a.scraper_asset_id<>b.scraper_asset_id
     OR a.scraper_contract_id<>b.scraper_contract_id
     OR retail.r1b_adapter_execution_ready(a.id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Dispatch binding does not match current R1B execution authority';
  END IF;

  PERFORM retail.r1d_validate_runner_policy(b.runner_policy_json);

  v_transport:=c.transport;
  IF v_transport='env' AND b.payload_delivery NOT IN('env','env_plus_stdin_json') THEN
    RAISE EXCEPTION 'env contract requires env-capable delivery';
  ELSIF v_transport='argv' AND b.payload_delivery<>'argv' THEN
    RAISE EXCEPTION 'argv contract requires argv delivery';
  ELSIF v_transport='json' AND b.payload_delivery<>'stdin_json' THEN
    RAISE EXCEPTION 'json contract requires stdin_json delivery';
  ELSIF v_transport='query' AND b.payload_delivery<>'stdin_json' THEN
    RAISE EXCEPTION 'query contract requires certified JSON bridge delivery';
  ELSIF v_transport='hybrid' AND b.payload_delivery<>'env_plus_stdin_json' THEN
    RAISE EXCEPTION 'hybrid contract requires env_plus_stdin_json delivery';
  END IF;

  IF b.runner_kind='node_js' THEN
    IF s.implementation_authority_type<>'file'
       OR s.entrypoint_ref IS NULL
       OR s.entrypoint_ref !~ '\.(js|mjs|cjs)$' THEN
      RAISE EXCEPTION 'node_js requires certified JavaScript file entrypoint';
    END IF;
  ELSIF b.runner_kind='tsx_file' THEN
    IF s.implementation_authority_type<>'file'
       OR s.entrypoint_ref IS NULL
       OR s.entrypoint_ref !~ '\.tsx?$' THEN
      RAISE EXCEPTION 'tsx_file requires certified TypeScript file entrypoint';
    END IF;
  ELSIF b.runner_kind='npm_script' THEN
    IF s.implementation_authority_type<>'package_tree'
       OR nullif(b.npm_script,'') IS NULL THEN
      RAISE EXCEPTION 'npm_script requires package-tree scraper';
    END IF;
    v_expected_script:='npm run '||b.npm_script;
    IF nullif(s.execution_command,'') IS NULL
       OR s.execution_command<>v_expected_script THEN
      RAISE EXCEPTION
        'npm_script must exactly match R1B certified execution_command (% vs %)',
        v_expected_script,s.execution_command;
    END IF;
  END IF;

  -- Environment mappings are certified at binding time; runtime will enforce
  -- the same reserved-name denylist.
  IF v_transport IN('env','hybrid') THEN
    FOR v_map_value IN
      SELECT value FROM jsonb_each_text(c.field_map)
    LOOP
      IF v_map_value !~ '^[A-Za-z_][A-Za-z0-9_]*$' THEN
        RAISE EXCEPTION 'Invalid env mapping name %',v_map_value;
      END IF;
      IF v_map_value=ANY(ARRAY[
        'PATH','NODE_OPTIONS','NODE_PATH','LD_PRELOAD','LD_LIBRARY_PATH',
        'DATABASE_URL','PGHOST','PGPORT','PGUSER','PGPASSWORD','PGDATABASE',
        'HOME','SHELL','TMPDIR','TEMP','TMP',
        'R1D_WORKER_ID','RETAIL_REPO_ROOT',
        'R1C_COMPILER_WRAPPER','R1C_BASE_MIGRATION','R1C_V3_MIGRATION',
        'R1C_PACKAGE_ZIP'
      ]) THEN
        RAISE EXCEPTION 'R1B field_map targets reserved environment name %',v_map_value;
      END IF;
    END LOOP;
  END IF;

  -- Evidence identity must match binding.
  IF p_evidence->>'adapter_id'<>b.adapter_id::text
     OR p_evidence->>'scraper_asset_id'<>b.scraper_asset_id::text
     OR p_evidence->>'scraper_contract_id'<>b.scraper_contract_id::text THEN
    RAISE EXCEPTION 'Certification evidence identity mismatch';
  END IF;

  v_expected_artifact_sha:=CASE
    WHEN s.implementation_authority_type='package_tree'
      THEN s.package_tree_sha256
    ELSE COALESCE(s.entrypoint_sha256,s.package_tree_sha256)
  END;

  IF p_evidence->>'artifact_sha256'<>v_expected_artifact_sha THEN
    RAISE EXCEPTION 'Certification evidence artifact SHA does not match R1B authority';
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

-- ---------- GEO ESCALATION STATE MACHINE ------------------------------------
CREATE TABLE IF NOT EXISTS retail.r1d_geo_transition_rules(
  parent_location_type text NOT NULL,
  child_location_type text NOT NULL,
  max_depth integer NOT NULL CHECK(max_depth BETWEEN 1 AND 10),
  active boolean NOT NULL DEFAULT true,
  PRIMARY KEY(parent_location_type,child_location_type),
  CHECK(parent_location_type IN('national','region','state','metro','postal_code','store')),
  CHECK(child_location_type IN('national','region','state','metro','postal_code','store'))
);

INSERT INTO retail.r1d_geo_transition_rules(
  parent_location_type,child_location_type,max_depth
)
VALUES
('national','region',1),
('national','state',1),
('region','metro',2),
('region','postal_code',2),
('state','metro',2),
('state','postal_code',2),
('metro','postal_code',3),
('postal_code','store',4)
ON CONFLICT DO NOTHING;


CREATE OR REPLACE FUNCTION retail.r1d_location_depth(p_location_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  WITH RECURSIVE chain AS (
    SELECT id,parent_location_id,1 depth
    FROM retail.search_locations
    WHERE id=p_location_id
    UNION ALL
    SELECT p.id,p.parent_location_id,c.depth+1
    FROM retail.search_locations p
    JOIN chain c ON c.parent_location_id=p.id
    WHERE c.depth<20
  )
  SELECT COALESCE(max(depth),0) FROM chain
$$;

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
  PERFORM retail.r1d_set_audit_context(p_process_run_id,p_correlation_id);

  IF p_max_children<1 OR p_max_children>100 THEN
    RAISE EXCEPTION 'Geo escalation max_children must be 1..100';
  END IF;

  SELECT j.id,j.target_id,j.platform_id,j.route_id,
         er.location_id,COALESCE(pl.location_type,'national') location_type
  INTO parent_rec
  FROM retail.effective_compiled_search_jobs j
  JOIN retail.effective_search_routes er ON er.route_id=j.route_id
  LEFT JOIN retail.search_locations pl ON pl.id=er.location_id
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
    JOIN retail.r1d_geo_transition_rules tr
      ON tr.parent_location_type=parent_rec.location_type
     AND tr.child_location_type=cl.location_type
     AND tr.active=true
     AND retail.r1d_location_depth(cl.id)<=tr.max_depth
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


ALTER TABLE retail.r1d_dispatch_attempts
  ADD COLUMN IF NOT EXISTS process_run_id uuid
    REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS correlation_id text;

CREATE OR REPLACE FUNCTION retail.r1d_attach_claim_provenance(
  p_job_id uuid,
  p_attempt_no integer,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM arb.process_runs
    WHERE run_id=p_process_run_id
      AND process_name='RETAIL_R1D_DISPATCH'
  ) THEN
    RAISE EXCEPTION 'Valid RETAIL_R1D_DISPATCH process run required';
  END IF;

  UPDATE retail.r1d_dispatch_attempts
  SET process_run_id=p_process_run_id,
      correlation_id=p_correlation_id
  WHERE job_id=p_job_id
    AND attempt_no=p_attempt_no
    AND process_run_id IS NULL;

  UPDATE retail.r1d_budget_ledger
  SET process_run_id=p_process_run_id,
      correlation_id=p_correlation_id
  WHERE job_id=p_job_id
    AND event_type='RESERVE'
    AND process_run_id IS NULL;
END $$;

-- ---------- CLAIM V2: CIRCUIT + RATE + CERTIFICATION SCOPE ------------------
CREATE OR REPLACE FUNCTION retail.r1d_claim_next_job_v2(
  p_worker_id text,
  p_process_run_id uuid,
  p_correlation_id text,
  p_certification_only boolean DEFAULT false
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
  estimated_cost_usd numeric,
  attempt_no integer
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
  v_rate uuid;
  v_circuit uuid;
  v_running integer;
  v_attempt integer;
BEGIN
  PERFORM set_config('app.actor_type','worker',true);
  PERFORM set_config('app.actor_id',p_worker_id,true);
  PERFORM set_config('app.actor_name',p_worker_id,true);
  IF p_process_run_id IS NOT NULL THEN
    PERFORM retail.r1d_set_audit_context(p_process_run_id,p_correlation_id);
  ELSIF p_correlation_id IS NOT NULL THEN
    PERFORM set_config('app.correlation_id',p_correlation_id,true);
  END IF;

  IF retail.r1d_r1c_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1D claim blocked: R1C V3 binding not current';
  END IF;

  FOR j IN
    SELECT q.*
    FROM retail.r1d_dispatch_jobs q
    WHERE q.status IN('queued','retry_wait')
      AND q.next_attempt_at<=now()
      AND q.certification_fixture=p_certification_only
      AND EXISTS(
        SELECT 1 FROM retail.r1d_cost_profiles cp
        WHERE cp.id=q.cost_profile_id
          AND cp.active=true
          AND cp.violation_status='clear'
      )
      AND EXISTS(
        SELECT 1 FROM retail.r1d_schedule_policies sp0
        WHERE sp0.id=q.schedule_policy_id AND sp0.active=true
      )
      AND EXISTS(
        SELECT 1 FROM retail.r1d_rate_policies rp
        WHERE rp.platform_id=q.platform_id AND rp.active=true
      )
    ORDER BY q.priority,q.scheduled_for,q.id
    FOR UPDATE SKIP LOCKED
    LIMIT 50
  LOOP
    IF NOT EXISTS(
      SELECT 1 FROM retail.effective_compiled_search_jobs ec
      WHERE ec.id=j.compilation_id
        AND ec.route_authority_hash=j.route_authority_hash
        AND ec.adapter_payload_sha256=j.adapter_payload_sha256
        AND ec.compiler_authority_sha256=j.compiler_authority_sha256
    ) OR retail.r1d_dispatch_binding_is_current(j.dispatch_binding_id) IS NOT TRUE THEN
      UPDATE retail.r1d_dispatch_jobs
      SET status='cancelled',
          last_error_code='STALE_EXECUTION_AUTHORITY',
          last_error_message='Compilation/binding authority no longer current',
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

    PERFORM pg_advisory_xact_lock(
      hashtextextended('r1d-platform:'||j.platform_id::text,0)
    );

    -- Recheck circuit after acquiring platform serialization.
    v_circuit:=retail.r1d_acquire_circuit_permit(
      j.platform_id,j.collection_source_id,now()
    );
    IF v_circuit IS NULL THEN CONTINUE; END IF;

    SELECT count(*)::int INTO v_running
    FROM retail.r1d_dispatch_jobs
    WHERE platform_id=j.platform_id
      AND status IN('leased','dispatching')
      AND lease_expires_at>now();
    IF v_running>=sp.max_parallel THEN
      PERFORM retail.r1d_release_circuit_permit(
        j.platform_id,j.collection_source_id,v_circuit
      );
      CONTINUE;
    END IF;

    SELECT count(*)::int INTO v_running
    FROM retail.r1d_dispatch_jobs
    WHERE dispatch_binding_id=j.dispatch_binding_id
      AND status IN('leased','dispatching')
      AND lease_expires_at>now();
    IF v_running>=db.max_concurrency THEN
      PERFORM retail.r1d_release_circuit_permit(
        j.platform_id,j.collection_source_id,v_circuit
      );
      CONTINUE;
    END IF;

    v_budget:=retail.r1d_reserve_budget_for_job(
      j.id,p_process_run_id,p_correlation_id
    );
    IF v_budget IS NULL THEN
      PERFORM retail.r1d_release_circuit_permit(
        j.platform_id,j.collection_source_id,v_circuit
      );
      CONTINUE;
    END IF;

    v_attempt:=j.attempt_count+1;
    v_rate:=retail.r1d_reserve_rate_slot_v2(j.id,v_attempt,now());
    IF v_rate IS NULL THEN
      PERFORM retail.r1d_release_budget(j.id,p_process_run_id,p_correlation_id);
      PERFORM retail.r1d_release_circuit_permit(
        j.platform_id,j.collection_source_id,v_circuit
      );
      CONTINUE;
    END IF;

    v_token:=gen_random_uuid();

    UPDATE retail.r1d_dispatch_jobs
    SET status='leased',
        attempt_count=v_attempt,
        lease_token=v_token,
        leased_by=p_worker_id,
        leased_at=now(),
        lease_expires_at=now()+make_interval(secs=>sp.lease_seconds),
        budget_reservation_group=v_budget,
        circuit_permit_token=v_circuit,
        updated_at=now()
    WHERE id=j.id;

    INSERT INTO retail.r1d_dispatch_attempts(
      job_id,attempt_no,worker_id,lease_token
    )
    VALUES(j.id,v_attempt,p_worker_id,v_token);

    RETURN QUERY
    SELECT
      j.id,v_token,now()+make_interval(secs=>sp.lease_seconds),
      ec.id,ec.adapter_id,j.dispatch_binding_id,
      ec.adapter_payload_json,ec.normalized_job_json,j.estimated_cost_usd,
      v_attempt
    FROM retail.effective_compiled_search_jobs ec
    WHERE ec.id=j.compilation_id;
    RETURN;
  END LOOP;
  RETURN;
END $$;

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
LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT job_id,lease_token,lease_expires_at,compilation_id,adapter_id,
         dispatch_binding_id,adapter_payload_json,normalized_job_json,
         estimated_cost_usd
  FROM retail.r1d_claim_next_job_v2(
    p_worker_id,p_process_run_id,p_correlation_id,false
  )
$$;

-- Consume rate only after child process has actually spawned / external outbox
-- delivery authority has been created.
CREATE OR REPLACE FUNCTION retail.r1d_mark_dispatching(
  p_job_id uuid,
  p_lease_token uuid
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  v_attempt integer;
BEGIN
  UPDATE retail.r1d_dispatch_jobs
  SET status='dispatching',updated_at=now()
  WHERE id=p_job_id
    AND status='leased'
    AND lease_token=p_lease_token
    AND lease_expires_at>now()
  RETURNING attempt_count INTO v_attempt;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Lease invalid/expired or job not leased';
  END IF;

  PERFORM retail.r1d_consume_rate_slot(p_job_id,v_attempt);
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
  PERFORM retail.r1d_set_audit_context(p_process_run_id,p_correlation_id);

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

  PERFORM retail.r1d_release_budget(j.id,p_process_run_id,p_correlation_id);
  PERFORM retail.r1d_release_rate_slot(j.id,j.attempt_count);
  PERFORM retail.r1d_release_circuit_permit(
    j.platform_id,j.collection_source_id,j.circuit_permit_token
  );

  UPDATE retail.r1d_dispatch_attempts
  SET completed_at=now(),success=false,
      error_code=p_error_code,error_message=left(p_error_message,4000),
      cost_basis='actual',actual_cost_usd=0
  WHERE job_id=j.id AND attempt_no=j.attempt_count;

  IF p_terminal OR j.attempt_count>=j.max_attempts THEN
    UPDATE retail.r1d_dispatch_jobs
    SET status='dead_letter',
        lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
        circuit_permit_token=NULL,
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
      j.attempt_count,jsonb_build_object('compilation_id',j.compilation_id)
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
        circuit_permit_token=NULL,
        last_error_code=p_error_code,
        last_error_message=left(p_error_message,4000),
        updated_at=now()
    WHERE id=j.id;
  END IF;
END $$;

-- Override completion to use atomic circuit state and strict budget settlement.
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
  PERFORM retail.r1d_set_audit_context(p_process_run_id,p_correlation_id);

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
    p_job_id,COALESCE(p_actual_cost_usd,j.estimated_cost_usd),
    COALESCE(p_cost_basis,'estimated'),
    p_process_run_id,p_correlation_id
  );

  PERFORM retail.r1d_complete_circuit_permit(
    j.platform_id,j.collection_source_id,j.circuit_permit_token,p_success
  );

  IF p_success THEN
    UPDATE retail.r1d_dispatch_jobs
    SET status='succeeded',
        lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
        circuit_permit_token=NULL,
        last_error_code=NULL,last_error_message=NULL,updated_at=now()
    WHERE id=p_job_id;

    UPDATE retail.r1d_compilation_schedule_state
    SET last_succeeded_at=now(),consecutive_failures=0,updated_at=now()
    WHERE compilation_id=j.compilation_id;
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
          circuit_permit_token=NULL,
          last_error_code=p_error_code,
          last_error_message=left(p_error_message,4000),
          updated_at=now()
      WHERE id=p_job_id;

      INSERT INTO retail.r1d_dead_letters(
        job_id,error_code,error_message,attempt_count,payload_snapshot
      )
      SELECT j.id,COALESCE(p_error_code,'DISPATCH_FAILED'),
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
          circuit_permit_token=NULL,
          last_error_code=p_error_code,
          last_error_message=left(p_error_message,4000),
          updated_at=now()
      WHERE id=p_job_id;
    END IF;

    UPDATE retail.r1d_compilation_schedule_state
    SET consecutive_failures=consecutive_failures+1,updated_at=now()
    WHERE compilation_id=j.compilation_id;
  END IF;
END $$;


CREATE OR REPLACE FUNCTION retail.r1d_enqueue_external_attempt(
  p_job_id uuid,
  p_lease_token uuid,
  p_binding_id uuid,
  p_payload jsonb
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  j retail.r1d_dispatch_jobs%ROWTYPE;
  v_message uuid;
BEGIN
  SELECT * INTO j
  FROM retail.r1d_dispatch_jobs
  WHERE id=p_job_id FOR UPDATE;

  IF NOT FOUND
     OR j.status<>'leased'
     OR j.lease_token IS DISTINCT FROM p_lease_token
     OR j.dispatch_binding_id IS DISTINCT FROM p_binding_id
     OR j.lease_expires_at<=now() THEN
    RAISE EXCEPTION 'External enqueue blocked: invalid lease/binding';
  END IF;

  INSERT INTO retail.r1d_dispatch_outbox(
    job_id,attempt_no,binding_id,lease_token,
    payload_json,payload_sha256,status
  )
  VALUES(
    j.id,j.attempt_count,p_binding_id,p_lease_token,
    p_payload,retail.r1d_sha256_jsonb(p_payload),'pending'
  )
  RETURNING outbox_message_id INTO v_message;

  PERFORM retail.r1d_mark_dispatching(j.id,p_lease_token);

  RETURN v_message;
END $$;

-- ---------- ATOMIC EXTERNAL COMPLETION --------------------------------------
CREATE OR REPLACE FUNCTION retail.r1d_finish_external_job(
  p_outbox_message_id uuid,
  p_lease_token uuid,
  p_success boolean,
  p_actual_cost_usd numeric,
  p_error_code text,
  p_error_message text,
  p_metrics jsonb,
  p_exit_code integer,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  o record;
BEGIN
  SELECT * INTO o
  FROM retail.r1d_dispatch_outbox
  WHERE outbox_message_id=p_outbox_message_id
  FOR UPDATE;

  IF NOT FOUND OR o.lease_token IS DISTINCT FROM p_lease_token THEN
    RAISE EXCEPTION 'External completion outbox/lease mismatch';
  END IF;

  IF o.status IN('delivered','failed') THEN
    RETURN; -- idempotent replay
  END IF;

  PERFORM retail.r1d_finish_job(
    o.job_id,p_lease_token,p_success,p_actual_cost_usd,
    CASE WHEN p_actual_cost_usd IS NULL THEN 'estimated' ELSE 'actual' END,
    p_error_code,p_error_message,COALESCE(p_metrics,'{}'::jsonb),
    p_exit_code,NULL,NULL,NULL,NULL,
    p_process_run_id,p_correlation_id
  );

  UPDATE retail.r1d_dispatch_outbox
  SET status=CASE WHEN p_success THEN 'delivered' ELSE 'failed' END,
      delivered_at=now()
  WHERE id=o.id;
END $$;

-- ---------- LEASE REAPER V2 -------------------------------------------------
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
  PERFORM retail.r1d_set_audit_context(p_process_run_id,p_correlation_id);

  FOR j IN
    SELECT * FROM retail.r1d_dispatch_jobs
    WHERE status IN('leased','dispatching')
      AND lease_expires_at<=p_now
    FOR UPDATE SKIP LOCKED
  LOOP
    IF j.status='leased' THEN
      PERFORM retail.r1d_release_budget(j.id,p_process_run_id,p_correlation_id);
      PERFORM retail.r1d_release_rate_slot(j.id,j.attempt_count);
      PERFORM retail.r1d_release_circuit_permit(
        j.platform_id,j.collection_source_id,j.circuit_permit_token
      );
    ELSE
      -- Request may have escaped; consume rate and settle reserved max.
      PERFORM retail.r1d_consume_rate_slot(j.id,j.attempt_count);
      PERFORM retail.r1d_settle_budget(
        j.id,j.estimated_cost_usd,'estimated',
        p_process_run_id,p_correlation_id
      );
      PERFORM retail.r1d_complete_circuit_permit(
        j.platform_id,j.collection_source_id,j.circuit_permit_token,false
      );
    END IF;

    UPDATE retail.r1d_dispatch_outbox
    SET status='cancelled'
    WHERE job_id=j.id
      AND attempt_no=j.attempt_count
      AND status='pending';

    IF j.attempt_count>=j.max_attempts THEN
      UPDATE retail.r1d_dispatch_jobs
      SET status='dead_letter',
          lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
          circuit_permit_token=NULL,
          last_error_code='LEASE_EXPIRED',
          last_error_message='Worker lease expired',
          updated_at=now()
      WHERE id=j.id;

      INSERT INTO retail.r1d_dead_letters(
        job_id,error_code,error_message,attempt_count,payload_snapshot
      )
      VALUES(
        j.id,'LEASE_EXPIRED','Worker lease expired',
        j.attempt_count,jsonb_build_object('compilation_id',j.compilation_id)
      )
      ON CONFLICT(job_id) DO NOTHING;
    ELSE
      UPDATE retail.r1d_dispatch_jobs
      SET status='retry_wait',
          next_attempt_at=p_now+interval '60 seconds',
          lease_token=NULL,leased_by=NULL,lease_expires_at=NULL,
          circuit_permit_token=NULL,
          last_error_code='LEASE_EXPIRED',
          last_error_message='Worker lease expired',
          updated_at=now()
      WHERE id=j.id;
    END IF;
    v_count:=v_count+1;
  END LOOP;
  RETURN v_count;
END $$;


CREATE OR REPLACE FUNCTION retail.r1d_sync_schedule_state_v2(
  p_now timestamptz,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
BEGIN
  PERFORM retail.r1d_set_audit_context(p_process_run_id,p_correlation_id);
  RETURN retail.r1d_sync_schedule_state(
    p_now,p_process_run_id,p_correlation_id
  );
END $$;

CREATE OR REPLACE FUNCTION retail.r1d_materialize_due_jobs_v2(
  p_now timestamptz,
  p_limit integer,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
BEGIN
  PERFORM retail.r1d_set_audit_context(p_process_run_id,p_correlation_id);
  RETURN retail.r1d_materialize_due_jobs(
    p_now,p_limit,p_process_run_id,p_correlation_id,p_actor
  );
END $$;

-- ---------- CERTIFICATION FORENSICS -----------------------------------------
ALTER TABLE retail.r1d_certification_runs
  ADD COLUMN IF NOT EXISTS evidence_manifest_text text,
  ADD COLUMN IF NOT EXISTS release_zip_sha256 text;


CREATE OR REPLACE FUNCTION retail.r1d_validate_certification_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.certification_version='r1d-v2.0.0' THEN
    IF NEW.evidence_manifest_text IS NULL
       OR NEW.release_zip_sha256 IS NULL
       OR NEW.release_zip_sha256!~'^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'R1D V2 certification requires canonical evidence text and release ZIP SHA';
    END IF;
    IF NEW.evidence_manifest_sha256<>
       retail.r1d_sha256_text(NEW.evidence_manifest_text) THEN
      RAISE EXCEPTION 'R1D V2 evidence manifest SHA mismatch';
    END IF;
    IF NEW.evidence_manifest IS DISTINCT FROM NEW.evidence_manifest_text::jsonb THEN
      RAISE EXCEPTION 'R1D V2 evidence JSON/text mismatch';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1d_validate_certification_insert
ON retail.r1d_certification_runs;
CREATE TRIGGER trg_r1d_validate_certification_insert
BEFORE INSERT ON retail.r1d_certification_runs
FOR EACH ROW EXECUTE FUNCTION retail.r1d_validate_certification_insert();

CREATE OR REPLACE FUNCTION retail.r1d_certification_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1D certification records are append-only and immutable';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1d_certification_guard
ON retail.r1d_certification_runs;
CREATE TRIGGER trg_r1d_certification_guard
BEFORE UPDATE OR DELETE ON retail.r1d_certification_runs
FOR EACH ROW EXECUTE FUNCTION retail.r1d_certification_guard();

CREATE OR REPLACE FUNCTION retail.r1d_history_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1D authority history is append-only';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1d_r1c_history_guard
ON retail.r1d_r1c_binding_history;
CREATE TRIGGER trg_r1d_r1c_history_guard
BEFORE UPDATE OR DELETE ON retail.r1d_r1c_binding_history
FOR EACH ROW EXECUTE FUNCTION retail.r1d_history_guard();

DROP TRIGGER IF EXISTS trg_r1d_budget_ledger_guard
ON retail.r1d_budget_ledger;
CREATE TRIGGER trg_r1d_budget_ledger_guard
BEFORE UPDATE OR DELETE ON retail.r1d_budget_ledger
FOR EACH ROW EXECUTE FUNCTION retail.r1d_history_guard();

DROP TRIGGER IF EXISTS trg_r1d_geo_events_guard
ON retail.r1d_geo_activation_events;
CREATE TRIGGER trg_r1d_geo_events_guard
BEFORE UPDATE OR DELETE ON retail.r1d_geo_activation_events
FOR EACH ROW EXECUTE FUNCTION retail.r1d_history_guard();

-- ---------- PRIVILEGES -------------------------------------------------------
REVOKE ALL ON FUNCTION retail.r1d_set_audit_context(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_reserve_rate_slot_v2(uuid,integer,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_consume_rate_slot(uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_release_rate_slot(uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_acquire_circuit_permit(uuid,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_release_circuit_permit(uuid,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_complete_circuit_permit(uuid,uuid,uuid,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_reconcile_stale_jobs(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_claim_next_job_v2(text,uuid,text,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_attach_claim_provenance(uuid,integer,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_enqueue_external_attempt(uuid,uuid,uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_finish_external_job(uuid,uuid,boolean,numeric,text,text,jsonb,integer,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_validate_runner_policy(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_location_depth(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_sync_schedule_state_v2(timestamptz,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1d_materialize_due_jobs_v2(timestamptz,integer,uuid,text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION retail.r1d_claim_next_job_v2(text,uuid,text,boolean)
  TO retail_r1d_dispatcher;
GRANT EXECUTE ON FUNCTION retail.r1d_attach_claim_provenance(uuid,integer,uuid,text)
  TO retail_r1d_dispatcher;
GRANT EXECUTE ON FUNCTION retail.r1d_enqueue_external_attempt(uuid,uuid,uuid,jsonb)
  TO retail_r1d_dispatcher;
GRANT EXECUTE ON FUNCTION retail.r1d_finish_external_job(uuid,uuid,boolean,numeric,text,text,jsonb,integer,uuid,text)
  TO retail_r1d_dispatcher;
GRANT EXECUTE ON FUNCTION retail.r1d_reconcile_stale_jobs(uuid,text)
  TO retail_r1d_scheduler;
GRANT EXECUTE ON FUNCTION retail.r1d_sync_schedule_state_v2(timestamptz,uuid,text)
  TO retail_r1d_scheduler;
GRANT EXECUTE ON FUNCTION retail.r1d_materialize_due_jobs_v2(timestamptz,integer,uuid,text,text)
  TO retail_r1d_scheduler;


DROP TRIGGER IF EXISTS trg_r1d_audit_rate_policies
ON retail.r1d_rate_policies;
CREATE TRIGGER trg_r1d_audit_rate_policies
AFTER INSERT OR UPDATE OR DELETE ON retail.r1d_rate_policies
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1d_log_retail_change();

COMMIT;
