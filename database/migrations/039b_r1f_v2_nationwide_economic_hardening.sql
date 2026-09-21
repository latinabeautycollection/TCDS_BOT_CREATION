BEGIN;

-- ============================================================================
-- TCDS RETAIL R1F V2
-- NATIONWIDE ECONOMIC SEARCH INTELLIGENCE — GREEN TIER 1 FINAL FREEZE
--
-- Final hardening:
--   full production-pipeline certification
--   landed/economic acquisition-cost comparison
--   condition + fulfillment + USD comparison cohorts
--   strict intelligence/certification policy validation
--   actual-vs-estimated cost coverage
--   collection count reconciliation
--   exact authorized geo-child compilation recommendations
--   local-time intelligence
--   future-window rejection
--   deterministic nationwide ranking
--   multi-cycle strategy-convergence certification
--   recommendation concurrency/idempotency certification
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('retail.r1f_schema_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1f_schema_state
       WHERE singleton=true AND schema_version='1.0.0'
     ) THEN
    RAISE EXCEPTION 'R1F V2 requires installed R1F V1 schema 1.0.0';
  END IF;

  IF retail.r1f_r1e_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1F V2 requires current certified R1E V2.1 binding';
  END IF;

  IF to_regclass('retail.search_locations') IS NULL
     OR to_regclass('retail.r1d_geo_transition_rules') IS NULL
     OR to_regclass('retail.r1d_compilation_schedule_state') IS NULL THEN
    RAISE EXCEPTION 'R1F V2 requires certified R1B/R1D geography authority';
  END IF;

  IF to_regclass('retail.product_inventory_history') IS NULL THEN
    RAISE EXCEPTION 'R1F V2 requires retail.product_inventory_history for fulfillment authority';
  END IF;
END $$;

CREATE TABLE retail.r1f_v2_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  hardening_version text NOT NULL,
  doctrine text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user
);

INSERT INTO retail.r1f_v2_state(singleton,hardening_version,doctrine)
VALUES(
  true,'2.0.0',
  'R1F V2 learns true U.S. retail acquisition economics by exact immutable product revision, comparable condition/fulfillment/currency cohort, geography and local time. It certifies the complete R1D→R1E→R1F production path and remains recommendation-only.'
);

-- ---------- SUPERSEDE V1 RUNTIME AUTHORITY ----------------------------------
REVOKE EXECUTE ON FUNCTION retail.r1f_ingest_completed_job(uuid,uuid,text,text)
  FROM retail_r1f_worker,retail_r1f_certifier;
REVOKE EXECUTE ON FUNCTION retail.r1f_build_intelligence(uuid,timestamptz,uuid,text,text)
  FROM retail_r1f_worker,retail_r1f_certifier;
REVOKE EXECUTE ON FUNCTION retail.r1f_generate_recommendations(uuid,timestamptz,uuid,text,text)
  FROM retail_r1f_worker,retail_r1f_certifier;

INSERT INTO arb.process_registry(
  process_name,phase_no,process_group,description,owner_team,active_flag
)
VALUES
('RETAIL_R1F_V2_E2E_CERTIFY',2,'RETAIL_AUTOMATION',
 'Execute full R1D→R1E→R1F production-pipeline certification scenarios.',
 'TCDS Retail Automation',true),
('RETAIL_R1F_V2_RECOMMEND_CONCURRENCY',2,'RETAIL_AUTOMATION',
 'Certify recommendation generation concurrency/idempotency.',
 'TCDS Retail Automation',true)
ON CONFLICT(process_name) DO NOTHING;

-- ---------- UTILITY / ECONOMIC NORMALIZATION --------------------------------
CREATE OR REPLACE FUNCTION retail.r1f_normalize_condition(p_value text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v text:=retail.r1e_normalize_text(p_value);
BEGIN
  RETURN CASE
    WHEN v IS NULL THEN 'UNKNOWN'
    WHEN v IN('new','brand new','new sealed','factory sealed') THEN 'NEW'
    WHEN v IN(
      'open box','openbox','open box excellent','open box good',
      'open box fair','opened'
    ) THEN 'OPEN_BOX'
    WHEN v IN(
      'refurbished','refurb','manufacturer refurbished',
      'certified refurbished','renewed'
    ) THEN 'REFURBISHED'
    WHEN v IN('used','pre owned','preowned') THEN 'USED'
    WHEN v IN('for parts','parts only','not working') THEN 'PARTS'
    ELSE upper(replace(v,' ','_'))
  END;
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_fulfillment_mode_for_capture(
  p_raw_capture_id uuid
)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  r record;
BEGIN
  SELECT
    bool_or(COALESCE(store_pickup_available,false)) pickup,
    bool_or(COALESCE(shipping_available,false)) shipping,
    bool_or(COALESCE(delivery_available,false)) delivery
  INTO r
  FROM retail.product_inventory_history
  WHERE raw_capture_id=p_raw_capture_id;

  IF COALESCE(r.pickup,false)
     AND NOT COALESCE(r.shipping,false)
     AND NOT COALESCE(r.delivery,false) THEN
    RETURN 'STORE_PICKUP';
  ELSIF COALESCE(r.shipping,false)
     AND NOT COALESCE(r.pickup,false)
     AND NOT COALESCE(r.delivery,false) THEN
    RETURN 'SHIP_TO_HOME';
  ELSIF COALESCE(r.delivery,false)
     AND NOT COALESCE(r.pickup,false)
     AND NOT COALESCE(r.shipping,false) THEN
    RETURN 'LOCAL_DELIVERY';
  ELSIF COALESCE(r.pickup,false)
     OR COALESCE(r.shipping,false)
     OR COALESCE(r.delivery,false) THEN
    RETURN 'MULTI_MODE';
  END IF;

  RETURN 'UNKNOWN';
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_economic_amount_document(
  p_observation_context jsonb
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_effective numeric:=retail.r1f_try_numeric(
    p_observation_context#>>'{offer,effective_price}'
  );
  v_shipping numeric:=retail.r1f_try_numeric(
    p_observation_context#>>'{offer,shipping_cost_estimate}'
  );
  v_tax numeric:=retail.r1f_try_numeric(
    p_observation_context#>>'{offer,estimated_tax}'
  );
  v_total numeric:=retail.r1f_try_numeric(
    p_observation_context#>>'{offer,estimated_total_cost}'
  );
  v_currency text:=upper(COALESCE(
    NULLIF(p_observation_context#>>'{offer,currency_code}',''),
    ''
  ));
  v_amount numeric;
  v_basis text;
BEGIN
  IF v_currency<>'USD' THEN
    RETURN jsonb_build_object(
      'supported',false,
      'currency_code',NULLIF(v_currency,''),
      'price_basis','UNSUPPORTED_CURRENCY'
    );
  END IF;

  IF v_total IS NOT NULL AND v_total>=0 THEN
    v_amount:=v_total;
    v_basis:='ESTIMATED_TOTAL_COST';
  ELSIF v_effective IS NOT NULL AND v_effective>=0 THEN
    v_amount:=v_effective
      +COALESCE(greatest(v_shipping,0),0)
      +COALESCE(greatest(v_tax,0),0);
    v_basis:=CASE
      WHEN v_shipping IS NOT NULL OR v_tax IS NOT NULL
      THEN 'EFFECTIVE_PLUS_KNOWN_SHIPPING_TAX'
      ELSE 'EFFECTIVE_PRICE_ONLY'
    END;
  ELSE
    RETURN jsonb_build_object(
      'supported',false,
      'currency_code','USD',
      'price_basis','MISSING_PRICE'
    );
  END IF;

  RETURN jsonb_build_object(
    'supported',true,
    'currency_code','USD',
    'economic_amount',round(v_amount,4),
    'price_basis',v_basis,
    'effective_price',v_effective,
    'shipping_cost_estimate',v_shipping,
    'estimated_tax',v_tax,
    'estimated_total_cost',v_total
  );
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_valid_timezone(p_timezone text)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT p_timezone IS NOT NULL
     AND EXISTS(
       SELECT 1 FROM pg_timezone_names
       WHERE name=p_timezone
     )
$$;

CREATE OR REPLACE FUNCTION retail.r1f_location_timezone(
  p_compilation_id uuid
)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT CASE
    WHEN j.location_id IS NULL THEN 'UTC'
    WHEN retail.r1f_valid_timezone(l.metadata->>'timezone')
      THEN l.metadata->>'timezone'
    ELSE NULL
  END
  FROM retail.search_job_compilations j
  LEFT JOIN retail.search_locations l ON l.id=j.location_id
  WHERE j.id=p_compilation_id
$$;

CREATE OR REPLACE FUNCTION retail.r1f_assert_window_end(
  p_window_end timestamptz,
  p_policy jsonb
)
RETURNS void
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_skew integer:=COALESCE(
    (p_policy->>'allowed_future_clock_skew_seconds')::int,
    300
  );
  v_days integer:=COALESCE((p_policy->>'lookback_days')::int,0);
BEGIN
  IF p_window_end IS NULL THEN
    RAISE EXCEPTION 'R1F window_end required';
  END IF;

  IF p_window_end>clock_timestamp()+make_interval(secs=>v_skew) THEN
    RAISE EXCEPTION 'R1F future window_end exceeds allowed clock skew';
  END IF;

  IF v_days<1 OR p_window_end-make_interval(days=>v_days)>=p_window_end THEN
    RAISE EXCEPTION 'R1F intelligence window invalid';
  END IF;
END $$;

-- ---------- STRICT V2 INTELLIGENCE POLICY -----------------------------------
CREATE OR REPLACE FUNCTION retail.r1f_validate_policy(p_policy jsonb)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_sum numeric;
  v_weight numeric;
  v_key text;
  v_hi numeric;
  v_low numeric;
BEGIN
  IF p_policy IS NULL OR jsonb_typeof(p_policy)<>'object' THEN
    RAISE EXCEPTION 'R1F policy must be JSON object';
  END IF;

  IF COALESCE((p_policy->>'lookback_days')::int,0) NOT BETWEEN 1 AND 180 THEN
    RAISE EXCEPTION 'lookback_days must be 1..180';
  END IF;

  IF COALESCE((p_policy->>'minimum_sample_jobs')::int,0) NOT BETWEEN 3 AND 10000 THEN
    RAISE EXCEPTION 'minimum_sample_jobs must be 3..10000';
  END IF;

  IF COALESCE(
       (p_policy->>'max_exploration_recommendations_per_run')::int,0
     ) NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION
      'max_exploration_recommendations_per_run must be 1..1000';
  END IF;

  v_sum:=0;
  FOREACH v_key IN ARRAY ARRAY[
    'qualification_yield','relative_bargain',
    'cost_efficiency','availability','freshness'
  ]
  LOOP
    v_weight:=COALESCE(
      (p_policy#>>ARRAY['score_weights',v_key])::numeric,-1
    );
    IF v_weight<0 OR v_weight>1 THEN
      RAISE EXCEPTION 'R1F score weight % must be 0..1',v_key;
    END IF;
    v_sum:=v_sum+v_weight;
  END LOOP;

  IF abs(v_sum-1)>0.0001 THEN
    RAISE EXCEPTION 'R1F score weights must sum to 1';
  END IF;

  IF COALESCE(
       (p_policy->>'bargain_pct_for_full_score')::numeric,0
     )<=0
     OR COALESCE(
       (p_policy->>'bargain_pct_for_full_score')::numeric,2
     )>1 THEN
    RAISE EXCEPTION 'bargain_pct_for_full_score must be >0 and <=1';
  END IF;

  IF COALESCE(
       (p_policy->>'max_cost_per_qualified_usd')::numeric,0
     )<=0
     OR COALESCE(
       (p_policy->>'max_cost_per_qualified_usd')::numeric,1001
     )>1000 THEN
    RAISE EXCEPTION 'max_cost_per_qualified_usd must be >0 and <=1000';
  END IF;

  IF COALESCE(
       (p_policy->>'freshness_days_for_zero')::numeric,0
     )<=0
     OR COALESCE(
       (p_policy->>'freshness_days_for_zero')::numeric,366
     )>365 THEN
    RAISE EXCEPTION 'freshness_days_for_zero must be >0 and <=365';
  END IF;

  v_hi:=COALESCE((p_policy->>'increase_frequency_score')::numeric,-1);
  v_low:=COALESCE((p_policy->>'decrease_frequency_score')::numeric,-1);

  IF v_low<0 OR v_low>100 OR v_hi<0 OR v_hi>100 OR v_low>=v_hi THEN
    RAISE EXCEPTION
      'R1F thresholds require 0<=decrease<increase<=100';
  END IF;

  IF COALESCE(
       (p_policy->>'high_opportunity_interval_seconds')::int,0
     ) NOT BETWEEN 300 AND 2592000
     OR COALESCE(
       (p_policy->>'low_opportunity_interval_seconds')::int,0
     ) NOT BETWEEN 300 AND 31536000
     OR COALESCE(
       (p_policy->>'exploration_interval_seconds')::int,0
     ) NOT BETWEEN 300 AND 31536000 THEN
    RAISE EXCEPTION 'R1F intervals outside governed range';
  END IF;

  IF COALESCE((p_policy->>'max_geo_fanout')::int,0) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'max_geo_fanout must be 1..100';
  END IF;

  IF COALESCE(
       (p_policy->>'recommendation_ttl_days')::int,0
     ) NOT BETWEEN 1 AND 30 THEN
    RAISE EXCEPTION 'recommendation_ttl_days must be 1..30';
  END IF;

  IF COALESCE(
       (p_policy->>'allowed_future_clock_skew_seconds')::int,-1
     ) NOT BETWEEN 0 AND 900 THEN
    RAISE EXCEPTION 'allowed_future_clock_skew_seconds must be 0..900';
  END IF;

  IF COALESCE(
       (p_policy->>'minimum_actual_cost_coverage_to_score')::numeric,-1
     )<0
     OR COALESCE(
       (p_policy->>'minimum_actual_cost_coverage_to_score')::numeric,2
     )>1
     OR COALESCE(
       (p_policy->>'actual_cost_coverage_for_full_score')::numeric,-1
     )<=0
     OR COALESCE(
       (p_policy->>'actual_cost_coverage_for_full_score')::numeric,2
     )>1
     OR (
       p_policy->>'minimum_actual_cost_coverage_to_score'
     )::numeric>
       (
         p_policy->>'actual_cost_coverage_for_full_score'
       )::numeric THEN
    RAISE EXCEPTION 'R1F actual-cost coverage thresholds invalid';
  END IF;

  IF COALESCE(p_policy->>'currency_mode','')<>'USD_ONLY' THEN
    RAISE EXCEPTION 'R1F V2 currency_mode must be USD_ONLY';
  END IF;

  IF COALESCE(p_policy->>'condition_baseline_mode','')<>'EXACT_CONDITION' THEN
    RAISE EXCEPTION
      'R1F V2 condition_baseline_mode must be EXACT_CONDITION';
  END IF;

  IF COALESCE(p_policy->>'fulfillment_baseline_mode','')<>'EXACT_FULFILLMENT' THEN
    RAISE EXCEPTION
      'R1F V2 fulfillment_baseline_mode must be EXACT_FULFILLMENT';
  END IF;
END $$;

-- ---------- CERTIFICATION POLICY TRANSITION HARDENING ------------------------
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

  IF OLD.certification_status IN('suspended','retired')
     AND NEW.certification_status<>OLD.certification_status
     AND NOT (
       OLD.certification_status='suspended'
       AND NEW.certification_status='retired'
     ) THEN
    RAISE EXCEPTION
      'Suspended/retired R1F certification policy cannot be reactivated';
  END IF;

  RETURN NEW;
END $$;

-- ---------- FACT MODEL V2 EXTENSIONS ----------------------------------------
ALTER TABLE retail.r1f_job_facts
  ADD COLUMN engine_version text NOT NULL DEFAULT 'r1f-v1.0.0',
  ADD COLUMN reported_records_collected integer,
  ADD COLUMN authoritative_capture_count integer,
  ADD COLUMN collection_reconciliation_status text,
  ADD COLUMN actual_cost_coverage numeric,
  ADD COLUMN location_timezone text,
  ADD COLUMN local_weekday integer,
  ADD COLUMN local_hour integer,
  ADD COLUMN certification_fixture boolean NOT NULL DEFAULT false,
  ADD COLUMN certification_batch_id uuid;

ALTER TABLE retail.r1f_job_facts
  ADD CONSTRAINT r1f_job_reconciliation_status_check
  CHECK(collection_reconciliation_status IN('MATCHED','MISSING_REPORTED_COUNT')),
  ADD CONSTRAINT r1f_job_actual_cost_coverage_check
  CHECK(actual_cost_coverage IS NULL OR actual_cost_coverage BETWEEN 0 AND 1),
  ADD CONSTRAINT r1f_job_local_weekday_check
  CHECK(local_weekday IS NULL OR local_weekday BETWEEN 1 AND 7),
  ADD CONSTRAINT r1f_job_local_hour_check
  CHECK(local_hour IS NULL OR local_hour BETWEEN 0 AND 23);

ALTER TABLE retail.r1f_observation_facts
  ADD COLUMN engine_version text NOT NULL DEFAULT 'r1f-v1.0.0',
  ADD COLUMN condition_normalized text,
  ADD COLUMN fulfillment_mode text,
  ADD COLUMN currency_code text,
  ADD COLUMN economic_amount numeric,
  ADD COLUMN economic_price_basis text,
  ADD COLUMN certification_fixture boolean NOT NULL DEFAULT false,
  ADD COLUMN certification_batch_id uuid;


ALTER TABLE retail.r1f_job_facts
  DROP CONSTRAINT IF EXISTS r1f_job_facts_r1d_job_id_r1e_certification_run_id_key;

CREATE UNIQUE INDEX uq_r1f_v2_job_fact_engine
ON retail.r1f_job_facts(
  r1d_job_id,r1e_certification_run_id,engine_version
);

ALTER TABLE retail.r1f_observation_facts
  DROP CONSTRAINT IF EXISTS r1f_observation_facts_r1e_result_id_key;

CREATE UNIQUE INDEX uq_r1f_v2_observation_fact_engine
ON retail.r1f_observation_facts(r1e_result_id,engine_version);

ALTER TABLE retail.r1f_observation_facts
  ADD CONSTRAINT r1f_observation_fulfillment_check
  CHECK(
    fulfillment_mode IS NULL OR fulfillment_mode IN(
      'STORE_PICKUP','SHIP_TO_HOME','LOCAL_DELIVERY','MULTI_MODE','UNKNOWN'
    )
  ),
  ADD CONSTRAINT r1f_observation_currency_check
  CHECK(currency_code IS NULL OR currency_code='USD'),
  ADD CONSTRAINT r1f_observation_economic_amount_check
  CHECK(economic_amount IS NULL OR economic_amount>=0),
  ADD CONSTRAINT r1f_observation_price_basis_check
  CHECK(
    economic_price_basis IS NULL OR economic_price_basis IN(
      'ESTIMATED_TOTAL_COST',
      'EFFECTIVE_PLUS_KNOWN_SHIPPING_TAX',
      'EFFECTIVE_PRICE_ONLY'
    )
  );

CREATE INDEX idx_r1f_v2_economic_baseline
ON retail.r1f_observation_facts(
  r1a_revision_hash,
  condition_normalized,
  fulfillment_mode,
  currency_code,
  economic_amount,
  observed_at
)
WHERE certification_fixture=false;

ALTER TABLE retail.r1f_intelligence_snapshots
  ADD COLUMN engine_version text NOT NULL DEFAULT 'r1f-v1.0.0',
  ADD COLUMN actual_cost_jobs integer,
  ADD COLUMN estimated_cost_jobs integer,
  ADD COLUMN actual_cost_coverage_pct numeric,
  ADD COLUMN certification_fixture boolean NOT NULL DEFAULT false,
  ADD COLUMN certification_batch_id uuid;

ALTER TABLE retail.r1f_intelligence_snapshots
  ADD CONSTRAINT r1f_snapshot_actual_cost_jobs_check
  CHECK(actual_cost_jobs IS NULL OR actual_cost_jobs>=0),
  ADD CONSTRAINT r1f_snapshot_estimated_cost_jobs_check
  CHECK(estimated_cost_jobs IS NULL OR estimated_cost_jobs>=0),
  ADD CONSTRAINT r1f_snapshot_actual_cost_coverage_check
  CHECK(
    actual_cost_coverage_pct IS NULL
    OR actual_cost_coverage_pct BETWEEN 0 AND 1
  );

ALTER TABLE retail.r1f_search_recommendations
  ADD COLUMN engine_version text NOT NULL DEFAULT 'r1f-v1.0.0',
  ADD COLUMN recommended_child_compilation_ids uuid[],
  ADD COLUMN certification_fixture boolean NOT NULL DEFAULT false,
  ADD COLUMN certification_batch_id uuid;

-- ---------- STRICT QA FIXTURE SEMANTICS -------------------------------------
ALTER TABLE retail.r1f_qa_fixtures
  DROP CONSTRAINT IF EXISTS r1f_qa_fixtures_fixture_class_check;

ALTER TABLE retail.r1f_qa_fixtures
  ADD CONSTRAINT r1f_qa_fixtures_fixture_class_check
  CHECK(fixture_class IN(
    'high_opportunity','low_opportunity','insufficient_sample',
    'high_cost','strong_bargain','weak_availability','exploration',
    'nationwide_ranking','strategy_convergence'
  ));

CREATE OR REPLACE FUNCTION retail.r1f_validate_qa_fixture(
  p_class text,
  p_input jsonb,
  p_expected jsonb
)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
  IF jsonb_typeof(p_input)<>'object'
     OR jsonb_typeof(p_expected)<>'object'
     OR p_expected='{}'::jsonb THEN
    RAISE EXCEPTION 'R1F fixture input/expected must be non-empty objects';
  END IF;

  IF p_class NOT IN('nationwide_ranking','strategy_convergence') THEN
    IF jsonb_typeof(p_input->'metrics')<>'object'
       OR jsonb_typeof(p_input->'snapshot')<>'object' THEN
      RAISE EXCEPTION
        'R1F scoring fixtures require input_json.metrics and input_json.snapshot objects';
    END IF;
  END IF;

  CASE p_class
    WHEN 'high_opportunity' THEN
      IF NOT (
        p_expected ? 'minimum_opportunity_score'
        AND p_expected ? 'recommendation_type'
      ) THEN
        RAISE EXCEPTION
          'high_opportunity requires minimum_opportunity_score and recommendation_type';
      END IF;
    WHEN 'low_opportunity' THEN
      IF NOT (
        p_expected ? 'maximum_opportunity_score'
        AND p_expected ? 'recommendation_type'
      ) THEN
        RAISE EXCEPTION
          'low_opportunity requires maximum_opportunity_score and recommendation_type';
      END IF;
    WHEN 'insufficient_sample','exploration' THEN
      IF p_expected->>'recommendation_type'<>'EXPLORATION_SAMPLE' THEN
        RAISE EXCEPTION
          '% requires recommendation_type EXPLORATION_SAMPLE',p_class;
      END IF;
    WHEN 'high_cost' THEN
      IF NOT (p_expected ? 'maximum_cost_efficiency_score') THEN
        RAISE EXCEPTION
          'high_cost requires maximum_cost_efficiency_score';
      END IF;
    WHEN 'strong_bargain' THEN
      IF NOT (
        p_expected ? 'minimum_bargain_score'
        AND p_expected ? 'recommendation_type'
      ) THEN
        RAISE EXCEPTION
          'strong_bargain requires minimum_bargain_score and recommendation_type';
      END IF;
    WHEN 'weak_availability' THEN
      IF NOT (p_expected ? 'maximum_availability_score') THEN
        RAISE EXCEPTION
          'weak_availability requires maximum_availability_score';
      END IF;
    WHEN 'nationwide_ranking' THEN
      IF jsonb_typeof(p_input->'locations')<>'array'
         OR jsonb_array_length(p_input->'locations')<4
         OR jsonb_typeof(p_expected->'ordered_location_codes')<>'array'
         OR jsonb_array_length(p_expected->'ordered_location_codes')<4
         OR jsonb_array_length(p_input->'locations')<>
            jsonb_array_length(p_expected->'ordered_location_codes') THEN
        RAISE EXCEPTION
          'nationwide_ranking requires >=4 locations and expected ordering';
      END IF;
    WHEN 'strategy_convergence' THEN
      IF jsonb_typeof(p_input->'cycles')<>'array'
         OR jsonb_array_length(p_input->'cycles')<4
         OR jsonb_typeof(p_expected->'expected_cycle_recommendations')<>'array'
         OR jsonb_array_length(p_expected->'expected_cycle_recommendations')<4
         OR jsonb_array_length(p_input->'cycles')<>
            jsonb_array_length(
              p_expected->'expected_cycle_recommendations'
            ) THEN
        RAISE EXCEPTION
          'strategy_convergence requires >=4 cycles and expected recommendations';
      END IF;
    ELSE
      RAISE EXCEPTION 'Unknown R1F fixture class %',p_class;
  END CASE;
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_prepare_fixture()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM retail.r1f_validate_qa_fixture(
    NEW.fixture_class,
    NEW.input_json,
    NEW.expected_json
  );

  NEW.fixture_sha256:=retail.r1f_sha256_jsonb(
    retail.r1f_fixture_document(NEW)
  );
  RETURN NEW;
END $$;

-- ---------- V2 SCORING / COST COVERAGE --------------------------------------
CREATE OR REPLACE FUNCTION retail.r1f_score_document_v2(
  p_metrics jsonb,
  p_policy jsonb
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_base jsonb;
  v_cost numeric;
  v_coverage numeric:=COALESCE(
    retail.r1f_try_numeric(p_metrics->>'actual_cost_coverage_pct'),0
  );
  v_min numeric:=
    (p_policy->>'minimum_actual_cost_coverage_to_score')::numeric;
  v_full numeric:=
    (p_policy->>'actual_cost_coverage_for_full_score')::numeric;
  v_factor numeric;
  v_total numeric;
BEGIN
  PERFORM retail.r1f_validate_policy(p_policy);

  v_base:=retail.r1f_score_document(p_metrics,p_policy);
  v_cost:=(v_base->>'cost_efficiency_score')::numeric;

  IF v_coverage<v_min THEN
    v_factor:=0;
  ELSE
    v_factor:=least(1,v_coverage/v_full);
  END IF;

  v_cost:=round(v_cost*v_factor,4);

  v_total:=round(
    (v_base->>'qualification_score')::numeric*
      (p_policy#>>'{score_weights,qualification_yield}')::numeric+
    (v_base->>'bargain_score')::numeric*
      (p_policy#>>'{score_weights,relative_bargain}')::numeric+
    v_cost*
      (p_policy#>>'{score_weights,cost_efficiency}')::numeric+
    (v_base->>'availability_score')::numeric*
      (p_policy#>>'{score_weights,availability}')::numeric+
    (v_base->>'freshness_score')::numeric*
      (p_policy#>>'{score_weights,freshness}')::numeric,
    4
  );

  RETURN v_base||jsonb_build_object(
    'cost_efficiency_score',v_cost,
    'actual_cost_coverage_pct',round(v_coverage,4),
    'cost_coverage_factor',round(v_factor,4),
    'opportunity_score',v_total
  );
END $$;

-- ---------- EXACT AUTHORIZED GEO CHILD RESOLUTION ---------------------------
CREATE OR REPLACE FUNCTION retail.r1f_authorized_child_compilations(
  p_parent_compilation_id uuid,
  p_policy_id uuid,
  p_window_end timestamptz,
  p_max_children integer
)
RETURNS uuid[]
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  parent_rec record;
  v_result uuid[];
BEGIN
  IF p_max_children<1 OR p_max_children>100 THEN
    RAISE EXCEPTION 'R1F child compilation fanout must be 1..100';
  END IF;

  SELECT
    j.id,j.target_id,j.r1a_revision_id,j.r1a_revision_hash,
    j.platform_id,j.route_id,
    er.location_id,
    COALESCE(pl.location_type,'national') location_type
  INTO parent_rec
  FROM retail.effective_compiled_search_jobs j
  JOIN retail.effective_search_routes er ON er.route_id=j.route_id
  LEFT JOIN retail.search_locations pl ON pl.id=er.location_id
  WHERE j.id=p_parent_compilation_id;

  IF NOT FOUND THEN
    RETURN ARRAY[]::uuid[];
  END IF;

  SELECT COALESCE(
    array_agg(x.compilation_id ORDER BY x.rank_score DESC,x.rotation_key),
    ARRAY[]::uuid[]
  )
  INTO v_result
  FROM (
    SELECT
      cj.id compilation_id,
      COALESCE((
        SELECT max(s.opportunity_score)
        FROM retail.r1f_intelligence_snapshots s
        WHERE s.policy_id=p_policy_id
          AND s.r1a_revision_hash=parent_rec.r1a_revision_hash
          AND s.platform_id=parent_rec.platform_id
          AND s.location_fingerprint=retail.r1f_sha256_jsonb(
            COALESCE(cj.normalized_job_json->'location','{}'::jsonb)
          )
          AND s.window_end<=p_window_end
          AND s.certification_fixture=false
      ),0) rank_score,
      hashtextextended(
        cj.id::text||':'||(p_window_end at time zone 'UTC')::date::text,
        0
      ) rotation_key
    FROM retail.effective_compiled_search_jobs cj
    JOIN retail.effective_search_routes cer ON cer.route_id=cj.route_id
    JOIN retail.search_locations cl ON cl.id=cer.location_id
    JOIN retail.r1d_compilation_schedule_state ss
      ON ss.compilation_id=cj.id
    JOIN retail.r1d_geo_transition_rules tr
      ON tr.parent_location_type=parent_rec.location_type
     AND tr.child_location_type=cl.location_type
     AND tr.active=true
     AND retail.r1d_location_depth(cl.id)<=tr.max_depth
    WHERE cj.target_id=parent_rec.target_id
      AND cj.r1a_revision_id=parent_rec.r1a_revision_id
      AND cj.r1a_revision_hash=parent_rec.r1a_revision_hash
      AND cj.platform_id=parent_rec.platform_id
      AND cj.id<>parent_rec.id
      AND ss.activation_state='suppressed'
      AND (
        (
          parent_rec.location_id IS NOT NULL
          AND cl.parent_location_id=parent_rec.location_id
        )
        OR
        (
          parent_rec.location_id IS NULL
          AND cl.parent_location_id IS NULL
        )
      )
    ORDER BY rank_score DESC,rotation_key
    LIMIT p_max_children
  ) x;

  RETURN v_result;
END $$;

-- ---------- V2 INGEST --------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1f_ingest_completed_job_v2(
  p_job_id uuid,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text,
  p_certification_fixture boolean DEFAULT false,
  p_certification_batch_id uuid DEFAULT NULL
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
  v_capture_total integer;
  v_result_total integer;
  v_qualified integer;
  v_rej_identity integer;
  v_rej_accessory integer;
  v_rej_condition integer;
  v_rej_duplicate integer;
  v_rej_incomplete integer;
  v_reported_collected integer;
  v_records_requested integer;
  v_cost numeric;
  v_cost_basis text;
  v_location jsonb;
  v_location_fp text;
  v_timezone text;
  v_fact_doc jsonb;
  v_fact_id uuid;
  q record;
  v_econ jsonb;
  v_condition text;
  v_fulfillment text;
  v_obs_doc jsonb;
  v_min_economic numeric;
  v_median_economic numeric;
  v_avg_economic numeric;
  v_in_stock integer;
BEGIN
  PERFORM retail.r1f_assert_process_run(
    p_process_run_id,
    CASE
      WHEN p_certification_fixture THEN
        ARRAY['RETAIL_R1F_V2_E2E_CERTIFY']
      ELSE
        ARRAY['RETAIL_R1F_INGEST_JOB']
    END
  );

  IF p_certification_fixture AND p_certification_batch_id IS NULL THEN
    RAISE EXCEPTION 'R1F V2 certification fixture requires certification_batch_id';
  ELSIF NOT p_certification_fixture AND p_certification_batch_id IS NOT NULL THEN
    RAISE EXCEPTION 'R1F V2 production ingest cannot set certification_batch_id';
  END IF;

  PERFORM set_config(
    'app.actor_type',
    CASE WHEN p_certification_fixture THEN 'system' ELSE 'worker' END,
    true
  );
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  IF retail.r1f_r1e_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1F V2 ingest blocked: R1E binding stale';
  END IF;

  SELECT * INTO b
  FROM retail.r1f_r1e_certification_binding
  WHERE singleton=true;

  SELECT * INTO rb
  FROM retail.r1e_r1d_certification_binding
  WHERE singleton=true;

  SELECT * INTO j
  FROM retail.r1d_dispatch_jobs
  WHERE id=p_job_id
    AND status='succeeded';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1F V2 requires succeeded R1D job';
  END IF;

  SELECT count(*)::int
  INTO v_attempt_count
  FROM retail.r1d_dispatch_attempts
  WHERE job_id=j.id
    AND success=true;

  IF v_attempt_count<>1 THEN
    RAISE EXCEPTION
      'R1F V2 requires exactly one successful R1D attempt, got %',
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
    RAISE EXCEPTION 'R1F V2 valid collection_run_id required';
  END IF;

  SELECT * INTO comp
  FROM retail.search_job_compilations
  WHERE id=j.compilation_id;

  IF NOT FOUND OR comp.platform_id IS DISTINCT FROM j.platform_id THEN
    RAISE EXCEPTION 'R1F V2 job/compilation authority mismatch';
  END IF;

  IF NOT EXISTS(
    SELECT 1
    FROM retail.collection_runs cr
    WHERE cr.id=v_collection_run_id
      AND cr.platform_id=j.platform_id
  ) THEN
    RAISE EXCEPTION 'R1F V2 collection run missing/platform mismatch';
  END IF;

  SELECT count(*)::int
  INTO v_capture_total
  FROM retail.raw_product_captures c
  WHERE c.collection_run_id=v_collection_run_id
    AND c.platform_id=j.platform_id;

  IF v_capture_total=0 THEN
    RAISE EXCEPTION 'R1F V2 collection run has no captures';
  END IF;

  v_reported_collected:=retail.r1f_try_integer(
    a.metrics_json->>'records_collected'
  );

  IF v_reported_collected IS NULL THEN
    RAISE EXCEPTION
      'R1F V2 requires R1D records_collected for reconciliation';
  END IF;

  IF v_reported_collected<>v_capture_total THEN
    RAISE EXCEPTION
      'R1F V2 collection reconciliation failed: worker %, database %',
      v_reported_collected,v_capture_total;
  END IF;

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
      'R1F V2 qualification cardinality incomplete (%/%)',
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
  JOIN retail.raw_product_captures c ON c.id=q0.raw_capture_id
  WHERE c.collection_run_id=v_collection_run_id
    AND c.platform_id=j.platform_id
    AND q0.ruleset_id=b.r1e_ruleset_id
    AND q0.r1d_certification_run_id=rb.r1d_certification_run_id
    AND q0.engine_version='r1e-v2.1.0'
    AND q0.certification_fixture=false
    AND retail.r1e_result_is_current(q0.id)=true;

  v_cost:=COALESCE(a.actual_cost_usd,j.estimated_cost_usd);
  IF v_cost IS NULL OR v_cost<0 THEN
    RAISE EXCEPTION 'R1F V2 valid job cost required';
  END IF;

  v_cost_basis:=CASE
    WHEN a.actual_cost_usd IS NOT NULL THEN 'actual'
    ELSE 'estimated'
  END;

  v_records_requested:=retail.r1f_try_integer(
    a.metrics_json->>'records_requested'
  );

  v_location:=COALESCE(comp.normalized_job_json->'location','{}'::jsonb);
  v_location_fp:=retail.r1f_sha256_jsonb(v_location);
  v_timezone:=retail.r1f_location_timezone(comp.id);

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
    source_process_run_id,source_correlation_id,
    engine_version,
    reported_records_collected,authoritative_capture_count,
    collection_reconciliation_status,actual_cost_coverage,
    location_timezone,local_weekday,local_hour,
    certification_fixture,certification_batch_id
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
    COALESCE(v_location->>'retailer_store_id',v_location->>'store_id'),
    COALESCE(v_location->>'postal_code',v_location->>'zip'),
    j.scheduled_for,a.completed_at,
    extract(isodow from a.completed_at)::int,
    extract(hour from a.completed_at at time zone 'UTC')::int,
    v_cost,v_cost_basis,
    v_records_requested,v_reported_collected,
    v_result_total,v_qualified,
    v_rej_identity,v_rej_accessory,v_rej_condition,
    v_rej_duplicate,v_rej_incomplete,
    NULL,NULL,NULL,0,
    '{}'::jsonb,repeat('0',64),
    p_process_run_id,p_correlation_id,
    'r1f-v2.0.0',
    v_reported_collected,v_capture_total,
    'MATCHED',
    CASE WHEN v_cost_basis='actual' THEN 1 ELSE 0 END,
    v_timezone,
    CASE
      WHEN v_timezone IS NULL THEN NULL
      ELSE extract(
        isodow from a.completed_at at time zone v_timezone
      )::int
    END,
    CASE
      WHEN v_timezone IS NULL THEN NULL
      ELSE extract(
        hour from a.completed_at at time zone v_timezone
      )::int
    END,
    p_certification_fixture,p_certification_batch_id
  )
  ON CONFLICT(r1d_job_id,r1e_certification_run_id,engine_version)
  DO NOTHING
  RETURNING id INTO v_fact_id;

  IF v_fact_id IS NULL THEN
    SELECT id INTO v_fact_id
    FROM retail.r1f_job_facts
    WHERE r1d_job_id=j.id
      AND r1e_certification_run_id=b.r1e_certification_run_id
      AND engine_version='r1f-v2.0.0';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'R1F V2 job fact conflict without existing row';
    END IF;

    IF EXISTS(
      SELECT 1 FROM retail.r1f_job_facts f
      WHERE f.id=v_fact_id
        AND (
          f.certification_fixture IS DISTINCT FROM p_certification_fixture
          OR f.certification_batch_id IS DISTINCT FROM p_certification_batch_id
          OR f.fact_sha256<>retail.r1f_sha256_jsonb(f.fact_document)
        )
    ) THEN
      RAISE EXCEPTION 'R1F V2 existing job fact certification/evidence mismatch';
    END IF;

    RETURN v_fact_id;
  END IF;

  -- Build V2 observation facts from every qualified current R1E result.
  FOR q IN
    SELECT q0.*
    FROM retail.r1e_qualification_results q0
    JOIN retail.raw_product_captures c ON c.id=q0.raw_capture_id
    WHERE c.collection_run_id=v_collection_run_id
      AND c.platform_id=j.platform_id
      AND q0.ruleset_id=b.r1e_ruleset_id
      AND q0.r1d_certification_run_id=rb.r1d_certification_run_id
      AND q0.engine_version='r1e-v2.1.0'
      AND q0.certification_fixture=false
      AND q0.decision='QUALIFIED'
      AND retail.r1e_result_is_current(q0.id)=true
  LOOP
    v_econ:=retail.r1f_economic_amount_document(
      q.observation_context_json
    );

    IF COALESCE((v_econ->>'supported')::boolean,false) IS NOT TRUE THEN
      RAISE EXCEPTION
        'R1F V2 economic observation unsupported for result %: %',
        q.id,v_econ;
    END IF;

    v_condition:=retail.r1f_normalize_condition(
      q.returned_identity_json->>'condition'
    );
    v_fulfillment:=retail.r1f_fulfillment_mode_for_capture(
      q.raw_capture_id
    );

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
      'condition_normalized',v_condition,
      'fulfillment_mode',v_fulfillment,
      'economic',v_econ,
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
      observation_document,observation_sha256,
      engine_version,
      condition_normalized,fulfillment_mode,currency_code,
      economic_amount,economic_price_basis,
      certification_fixture,certification_batch_id
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
      v_obs_doc,retail.r1f_sha256_jsonb(v_obs_doc),
      'r1f-v2.0.0',
      v_condition,v_fulfillment,'USD',
      (v_econ->>'economic_amount')::numeric,
      v_econ->>'price_basis',
      p_certification_fixture,p_certification_batch_id
    )
    ON CONFLICT(r1e_result_id,engine_version) DO NOTHING;
  END LOOP;

  SELECT
    min(o.economic_amount),
    percentile_cont(0.5) within group(order by o.economic_amount),
    avg(o.economic_amount),
    count(*) filter(
      where lower(COALESCE(o.availability,'')) in(
        'in_stock','available',
        'available_for_pickup','available_for_shipping'
      )
    )::int
  INTO v_min_economic,v_median_economic,v_avg_economic,v_in_stock
  FROM retail.r1f_observation_facts o
  WHERE o.r1f_job_fact_id=v_fact_id;

  v_fact_doc:=jsonb_build_object(
    'engine_version','r1f-v2.0.0',
    'r1e_certification_run_id',b.r1e_certification_run_id,
    'r1e_package_sha256',b.r1e_package_sha256,
    'r1d_job_id',j.id,
    'r1d_attempt_id',a.id,
    'collection_run_id',v_collection_run_id,
    'compilation_id',comp.id,
    'target_id',comp.target_id,
    'r1a_revision_id',comp.r1a_revision_id,
    'r1a_revision_hash',comp.r1a_revision_hash,
    'platform_id',comp.platform_id,
    'location',v_location,
    'location_timezone',v_timezone,
    'completed_at',a.completed_at,
    'search_cost_usd',v_cost,
    'cost_basis',v_cost_basis,
    'reported_records_collected',v_reported_collected,
    'authoritative_capture_count',v_capture_total,
    'collection_reconciliation_status','MATCHED',
    'qualification_counts',jsonb_build_object(
      'total',v_result_total,
      'qualified',v_qualified,
      'rejected_identity',v_rej_identity,
      'rejected_accessory',v_rej_accessory,
      'rejected_condition',v_rej_condition,
      'rejected_duplicate',v_rej_duplicate,
      'rejected_incomplete',v_rej_incomplete
    ),
    'economic_amounts',jsonb_build_object(
      'min',v_min_economic,
      'median',v_median_economic,
      'avg',v_avg_economic
    ),
    'in_stock_qualified',v_in_stock,
    'certification_fixture',p_certification_fixture
  );

  -- Immutable-row guard prevents ordinary UPDATE; this single finalize step is
  -- performed within the same function before the row leaves its creation
  -- transaction by temporarily setting a transaction-local finalization flag.
  PERFORM set_config('r1f.fact_finalize','true',true);

  UPDATE retail.r1f_job_facts
  SET min_qualified_price=v_min_economic,
      median_qualified_price=v_median_economic,
      avg_qualified_price=v_avg_economic,
      in_stock_qualified=v_in_stock,
      fact_document=v_fact_doc,
      fact_sha256=retail.r1f_sha256_jsonb(v_fact_doc)
  WHERE id=v_fact_id;

  PERFORM set_config('r1f.fact_finalize','false',true);

  RETURN v_fact_id;
END $$;

-- Permit only the creation-transaction finalization performed above.
CREATE OR REPLACE FUNCTION retail.r1f_fact_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='UPDATE'
     AND current_setting('r1f.fact_finalize',true)='true'
     AND OLD.fact_document='{}'::jsonb
     AND OLD.fact_sha256=repeat('0',64)
     AND NEW.id=OLD.id
     AND NEW.r1d_job_id=OLD.r1d_job_id
     AND NEW.r1d_attempt_id=OLD.r1d_attempt_id
     AND NEW.r1e_certification_run_id=OLD.r1e_certification_run_id
     AND NEW.compilation_id=OLD.compilation_id
     AND NEW.target_id=OLD.target_id THEN
    RETURN NEW;
  END IF;

  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1F job facts are immutable';
  END IF;

  RETURN NEW;
END $$;

-- ---------- V2 INTELLIGENCE BUILD -------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1f_build_intelligence_v2(
  p_policy_id uuid,
  p_window_end timestamptz,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text,
  p_certification_fixture boolean DEFAULT false,
  p_certification_batch_id uuid DEFAULT NULL
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
    CASE
      WHEN p_certification_fixture THEN
        ARRAY['RETAIL_R1F_V2_E2E_CERTIFY']
      ELSE
        ARRAY['RETAIL_R1F_BUILD_INTELLIGENCE']
    END
  );

  IF p_certification_fixture AND p_certification_batch_id IS NULL THEN
    RAISE EXCEPTION 'R1F V2 certification build requires certification_batch_id';
  ELSIF NOT p_certification_fixture AND p_certification_batch_id IS NOT NULL THEN
    RAISE EXCEPTION 'R1F V2 production build cannot set certification_batch_id';
  END IF;

  IF retail.r1f_r1e_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1F V2 intelligence blocked: R1E binding stale';
  END IF;

  SELECT * INTO p
  FROM retail.r1f_intelligence_policies
  WHERE id=p_policy_id
    AND certification_status='certified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Certified R1F intelligence policy required';
  END IF;

  PERFORM retail.r1f_validate_policy(p.policy_json);
  PERFORM retail.r1f_assert_window_end(p_window_end,p.policy_json);

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'r1f-v2-build:'||p_policy_id::text||':'||p_window_end::text||':'||
      COALESCE(p_certification_batch_id::text,'production'),
      0
    )
  );

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
        count(*) filter(where f.cost_basis in('actual','allocated_provider'))::int actual_cost_jobs,
        count(*) filter(where f.cost_basis='estimated')::int estimated_cost_jobs,
        count(*) filter(where f.cost_basis in('actual','allocated_provider'))::numeric/
          count(*) actual_cost_coverage_pct,
        max(f.completed_at) last_completed_at
      FROM retail.r1f_job_facts f
      WHERE f.r1e_certification_run_id=b.r1e_certification_run_id
        AND f.completed_at>=v_start
        AND f.completed_at<=p_window_end
        AND f.certification_fixture=p_certification_fixture
        AND f.certification_batch_id IS NOT DISTINCT FROM p_certification_batch_id
        AND f.engine_version='r1f-v2.0.0'
        AND f.fact_sha256=retail.r1f_sha256_jsonb(f.fact_document)
        AND f.collection_reconciliation_status='MATCHED'
      GROUP BY
        f.target_id,f.r1a_revision_id,f.r1a_revision_hash,
        f.platform_id,f.collection_source_id,f.location_fingerprint
    ),
    observation_relative AS (
      SELECT
        o.target_id,
        o.r1a_revision_id,
        o.r1a_revision_hash,
        o.platform_id,
        f.collection_source_id,
        o.location_fingerprint,
        o.condition_normalized,
        o.fulfillment_mode,
        o.currency_code,
        o.economic_amount,
        o.availability,
        ref.reference_amount,
        CASE
          WHEN o.economic_amount IS NULL
            OR ref.reference_amount IS NULL
            OR ref.reference_amount<=0
          THEN NULL
          ELSE greatest(
            0,
            (ref.reference_amount-o.economic_amount)/ref.reference_amount
          )
        END relative_bargain_pct
      FROM retail.r1f_observation_facts o
      JOIN retail.r1f_job_facts f ON f.id=o.r1f_job_fact_id
      JOIN LATERAL (
        SELECT percentile_cont(0.5) within group(
          order by o2.economic_amount
        ) reference_amount
        FROM retail.r1f_observation_facts o2
        JOIN retail.r1f_job_facts f2 ON f2.id=o2.r1f_job_fact_id
        WHERE o2.r1a_revision_hash=o.r1a_revision_hash
          AND o2.condition_normalized=o.condition_normalized
          AND o2.fulfillment_mode=o.fulfillment_mode
          AND o2.currency_code=o.currency_code
          AND o2.currency_code='USD'
          AND o2.economic_amount IS NOT NULL
          AND o2.certification_fixture=p_certification_fixture
          AND o2.certification_batch_id IS NOT DISTINCT FROM p_certification_batch_id
          AND o2.engine_version='r1f-v2.0.0'
          AND f2.r1e_certification_run_id=b.r1e_certification_run_id
          AND f2.engine_version='r1f-v2.0.0'
          AND f2.completed_at>=v_start
          AND f2.completed_at<=p_window_end
      ) ref ON true
      WHERE f.r1e_certification_run_id=b.r1e_certification_run_id
        AND f.completed_at>=v_start
        AND f.completed_at<=p_window_end
        AND f.certification_fixture=p_certification_fixture
        AND f.certification_batch_id IS NOT DISTINCT FROM p_certification_batch_id
        AND f.engine_version='r1f-v2.0.0'
        AND o.certification_fixture=p_certification_fixture
        AND o.certification_batch_id IS NOT DISTINCT FROM p_certification_batch_id
        AND o.engine_version='r1f-v2.0.0'
        AND o.currency_code='USD'
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
        min(economic_amount) best_local_amount,
        percentile_cont(0.5) within group(
          order by economic_amount
        ) filter(where economic_amount is not null) median_local_amount,
        percentile_cont(0.5) within group(
          order by reference_amount
        ) filter(where reference_amount is not null) median_reference_amount,
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
        target_id,r1a_revision_id,r1a_revision_hash,
        platform_id,collection_source_id,location_fingerprint
    )
    SELECT
      fa.*,
      oa.best_local_amount,
      oa.median_local_amount,
      oa.median_reference_amount,
      COALESCE(oa.median_relative_bargain_pct,0)
        median_relative_bargain_pct,
      COALESCE(oa.available_qualified,0) available_qualified
    FROM fact_agg fa
    LEFT JOIN obs_agg oa
      ON oa.target_id=fa.target_id
     AND oa.r1a_revision_hash=fa.r1a_revision_hash
     AND oa.platform_id=fa.platform_id
     AND oa.collection_source_id IS NOT DISTINCT FROM fa.collection_source_id
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
        ),
      'actual_cost_coverage_pct',r.actual_cost_coverage_pct
    );

    v_scores:=retail.r1f_score_document_v2(
      v_metrics,p.policy_json
    );

    v_doc:=jsonb_build_object(
      'engine_version','r1f-v2.0.0',
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
      'actual_cost_jobs',r.actual_cost_jobs,
      'estimated_cost_jobs',r.estimated_cost_jobs,
      'best_local_economic_amount',r.best_local_amount,
      'median_local_economic_amount',r.median_local_amount,
      'median_reference_economic_amount',r.median_reference_amount,
      'scores',v_scores,
      'certification_fixture',p_certification_fixture
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
      source_process_run_id,source_correlation_id,
      engine_version,
      actual_cost_jobs,estimated_cost_jobs,actual_cost_coverage_pct,
      certification_fixture,certification_batch_id
    )
    VALUES(
      p.id,p.policy_sha256,b.r1e_certification_run_id,
      r.target_id,r.r1a_revision_id,r.r1a_revision_hash,
      r.platform_id,r.collection_source_id,
      r.location_fingerprint,r.location_context_json,
      v_start,p_window_end,
      r.sample_jobs,r.total_observations,r.qualified_observations,
      CASE WHEN r.total_observations=0 THEN 0
        ELSE r.qualified_observations::numeric/r.total_observations END,
      r.total_cost_usd,r.cost_per_job_usd,r.cost_per_qualified_usd,
      r.median_local_amount,r.median_reference_amount,r.best_local_amount,
      r.median_relative_bargain_pct,
      r.available_qualified,
      CASE WHEN r.qualified_observations=0 THEN 0
        ELSE least(
          1,r.available_qualified::numeric/r.qualified_observations
        ) END,
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
      p_process_run_id,p_correlation_id,
      'r1f-v2.0.0',
      r.actual_cost_jobs,r.estimated_cost_jobs,r.actual_cost_coverage_pct,
      p_certification_fixture,p_certification_batch_id
    )
    ON CONFLICT DO NOTHING;

    v_count:=v_count+1;
  END LOOP;

  RETURN v_count;
END $$;

-- ---------- V2 RECOMMENDATION GENERATION ------------------------------------
CREATE OR REPLACE FUNCTION retail.r1f_generate_recommendations_v2(
  p_policy_id uuid,
  p_window_end timestamptz,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text,
  p_certification_fixture boolean DEFAULT false,
  p_certification_batch_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  p retail.r1f_intelligence_policies%ROWTYPE;
  s retail.r1f_intelligence_snapshots%ROWTYPE;
  b retail.r1f_r1e_certification_binding%ROWTYPE;
  ec record;
  v_decision jsonb;
  v_children uuid[];
  v_doc jsonb;
  v_key text;
  v_count integer:=0;
  v_compilation uuid;
  v_compilation_count integer;
  v_inserted integer;
BEGIN
  PERFORM retail.r1f_assert_process_run(
    p_process_run_id,
    CASE
      WHEN p_certification_fixture THEN
        ARRAY[
          'RETAIL_R1F_V2_E2E_CERTIFY',
          'RETAIL_R1F_V2_RECOMMEND_CONCURRENCY'
        ]
      ELSE
        ARRAY['RETAIL_R1F_RECOMMEND']
    END
  );

  IF p_certification_fixture AND p_certification_batch_id IS NULL THEN
    RAISE EXCEPTION 'R1F V2 certification recommendation requires certification_batch_id';
  ELSIF NOT p_certification_fixture AND p_certification_batch_id IS NOT NULL THEN
    RAISE EXCEPTION 'R1F V2 production recommendation cannot set certification_batch_id';
  END IF;

  IF retail.r1f_r1e_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1F V2 recommendations blocked: R1E binding stale';
  END IF;

  SELECT * INTO p
  FROM retail.r1f_intelligence_policies
  WHERE id=p_policy_id
    AND certification_status='certified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Certified R1F intelligence policy required';
  END IF;

  PERFORM retail.r1f_validate_policy(p.policy_json);
  PERFORM retail.r1f_assert_window_end(p_window_end,p.policy_json);

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'r1f-v2-rec:'||p_policy_id::text||':'||
      p_window_end::text||':'||p_certification_fixture::text||':'||
      COALESCE(p_certification_batch_id::text,'production'),
      0
    )
  );

  SELECT * INTO b
  FROM retail.r1f_r1e_certification_binding
  WHERE singleton=true;

  FOR s IN
    SELECT *
    FROM retail.r1f_intelligence_snapshots
    WHERE policy_id=p.id
      AND window_end=p_window_end
      AND certification_fixture=p_certification_fixture
      AND certification_batch_id IS NOT DISTINCT FROM p_certification_batch_id
      AND engine_version='r1f-v2.0.0'
    ORDER BY opportunity_score DESC,id
  LOOP
    SELECT
      count(*)::int,
      (array_agg(ec0.id ORDER BY ec0.id::text))[1]
    INTO v_compilation_count,v_compilation
    FROM retail.effective_compiled_search_jobs ec0
    WHERE ec0.target_id=s.target_id
      AND ec0.r1a_revision_id=s.r1a_revision_id
      AND ec0.r1a_revision_hash=s.r1a_revision_hash
      AND ec0.platform_id=s.platform_id
      AND retail.r1f_sha256_jsonb(
        COALESCE(ec0.normalized_job_json->'location','{}'::jsonb)
      )=s.location_fingerprint;

    IF v_compilation_count<>1 THEN
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

    v_children:=ARRAY[]::uuid[];

    IF v_decision->>'recommendation_type'='EXPAND_GEO_CHILDREN' THEN
      v_children:=retail.r1f_authorized_child_compilations(
        v_compilation,
        p.id,
        p_window_end,
        COALESCE(
          (v_decision->>'recommended_geo_fanout')::int,
          (p.policy_json->>'max_geo_fanout')::int
        )
      );

      IF cardinality(v_children)=0 THEN
        v_decision:=jsonb_build_object(
          'recommendation_type','MAINTAIN',
          'recommendation_priority',700,
          'exploration',false
        );
      END IF;
    END IF;

    v_doc:=jsonb_build_object(
      'engine_version','r1f-v2.0.0',
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
      'recommended_child_compilation_ids',to_jsonb(v_children),
      'expires_at',p_window_end+
        make_interval(days=>
          (p.policy_json->>'recommendation_ttl_days')::int
        ),
      'certification_fixture',p_certification_fixture
    );

    v_key:=retail.r1f_sha256_jsonb(jsonb_build_object(
      'engine_version','r1f-v2.0.0',
      'policy_id',p.id,
      'snapshot_id',s.id,
      'compilation_id',v_compilation,
      'recommendation_type',v_decision->>'recommendation_type',
      'certification_fixture',p_certification_fixture
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
      source_process_run_id,source_correlation_id,
      engine_version,
      recommended_child_compilation_ids,certification_fixture,
      certification_batch_id
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
      CASE
        WHEN cardinality(v_children)>0 THEN cardinality(v_children)
        ELSE retail.r1f_try_integer(
          v_decision->>'recommended_geo_fanout'
        )
      END,
      COALESCE((v_decision->>'exploration')::boolean,false),
      (v_doc->>'expires_at')::timestamptz,
      v_doc,retail.r1f_sha256_jsonb(v_doc),
      p_process_run_id,p_correlation_id,
      'r1f-v2.0.0',
      v_children,p_certification_fixture,p_certification_batch_id
    )
    ON CONFLICT(recommendation_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    v_count:=v_count+v_inserted;
  END LOOP;

  -- Keep bounded exploration alive so early winners cannot permanently starve
  -- unsampled authorized U.S. routes.
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
        AND f.certification_fixture=p_certification_fixture
        AND f.certification_batch_id IS NOT DISTINCT FROM p_certification_batch_id
        AND f.engine_version='r1f-v2.0.0'
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
        (p.policy_json->>'exploration_interval_seconds')::int,
      'exploration',true
    );

    v_doc:=jsonb_build_object(
      'engine_version','r1f-v2.0.0',
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
      'recommendation',v_decision,
      'recommendation_basis','UNSAMPLED_AUTHORIZED_ROUTE',
      'expires_at',p_window_end+
        make_interval(days=>
          (p.policy_json->>'recommendation_ttl_days')::int
        ),
      'certification_fixture',p_certification_fixture
    );

    v_key:=retail.r1f_sha256_jsonb(jsonb_build_object(
      'engine_version','r1f-v2.0.0',
      'policy_id',p.id,
      'window_end',p_window_end,
      'compilation_id',ec.compilation_id,
      'recommendation_type','EXPLORATION_SAMPLE',
      'certification_fixture',p_certification_fixture
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
      source_process_run_id,source_correlation_id,
      engine_version,
      recommended_child_compilation_ids,certification_fixture,
      certification_batch_id
    )
    VALUES(
      v_key,
      p.id,p.policy_sha256,NULL,b.r1e_certification_run_id,
      ec.target_id,ec.r1a_revision_id,ec.r1a_revision_hash,
      ec.platform_id,ec.compilation_id,
      retail.r1f_sha256_jsonb(ec.location_context),
      'EXPLORATION_SAMPLE',600,
      (p.policy_json->>'exploration_interval_seconds')::int,
      NULL,true,
      (v_doc->>'expires_at')::timestamptz,
      v_doc,retail.r1f_sha256_jsonb(v_doc),
      p_process_run_id,p_correlation_id,
      'r1f-v2.0.0',
      ARRAY[]::uuid[],p_certification_fixture,p_certification_batch_id
    )
    ON CONFLICT(recommendation_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    v_count:=v_count+v_inserted;
  END LOOP;

  RETURN v_count;
END $$;

-- ---------- LOCAL-TIME INTELLIGENCE -----------------------------------------
CREATE OR REPLACE VIEW retail.r1f_local_temporal_search_intelligence AS
SELECT
  f.target_id,
  f.r1a_revision_id,
  f.r1a_revision_hash,
  f.platform_id,
  f.collection_source_id,
  f.location_fingerprint,
  f.location_context_json,
  f.location_timezone,
  f.local_weekday,
  f.local_hour,
  count(*)::int sample_jobs,
  sum(f.observations_total)::int total_observations,
  sum(f.qualified_observations)::int qualified_observations,
  CASE
    WHEN sum(f.observations_total)=0 THEN 0
    ELSE sum(f.qualified_observations)::numeric/
         sum(f.observations_total)
  END qualification_rate,
  sum(f.actual_cost_usd) total_cost_usd,
  count(*) filter(where f.cost_basis in('actual','allocated_provider'))::numeric/
    count(*) actual_cost_coverage_pct,
  CASE
    WHEN sum(f.qualified_observations)=0 THEN NULL
    ELSE sum(f.actual_cost_usd)/sum(f.qualified_observations)
  END cost_per_qualified_usd,
  min(f.min_qualified_price) best_qualified_economic_amount,
  max(f.completed_at) last_completed_at_utc
FROM retail.r1f_job_facts f
JOIN retail.r1f_r1e_certification_binding b
  ON b.singleton=true
 AND b.r1e_certification_run_id=f.r1e_certification_run_id
WHERE retail.r1f_r1e_binding_is_current()=true
  AND f.certification_fixture=false
  AND f.engine_version='r1f-v2.0.0'
  AND f.location_timezone IS NOT NULL
  AND f.local_weekday IS NOT NULL
  AND f.local_hour IS NOT NULL
  AND f.fact_sha256=retail.r1f_sha256_jsonb(f.fact_document)
GROUP BY
  f.target_id,f.r1a_revision_id,f.r1a_revision_hash,
  f.platform_id,f.collection_source_id,
  f.location_fingerprint,f.location_context_json,
  f.location_timezone,f.local_weekday,f.local_hour;

-- ---------- NATIONWIDE RANKING / CONVERGENCE QA -----------------------------
CREATE OR REPLACE FUNCTION retail.r1f_rank_locations(
  p_locations jsonb,
  p_policy jsonb
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF jsonb_typeof(p_locations)<>'array'
     OR jsonb_array_length(p_locations)<1 THEN
    RAISE EXCEPTION 'R1F ranking locations must be non-empty array';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'location_code',x.location_code,
      'score',x.score
    )
    ORDER BY x.score DESC,x.location_code
  )
  INTO v_result
  FROM (
    SELECT
      e->>'location_code' location_code,
      (
        retail.r1f_score_document_v2(
          e->'metrics',p_policy
        )->>'opportunity_score'
      )::numeric score
    FROM jsonb_array_elements(p_locations) AS t(e)
  ) x;

  RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_simulate_strategy(
  p_cycles jsonb,
  p_policy jsonb
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  c jsonb;
  l jsonb;
  v_cycle integer:=0;
  v_out jsonb:='[]'::jsonb;
  v_ranked jsonb;
  v_top jsonb;
  v_decision jsonb;
  v_exploration_count integer;
BEGIN
  IF jsonb_typeof(p_cycles)<>'array'
     OR jsonb_array_length(p_cycles)<1 THEN
    RAISE EXCEPTION 'R1F strategy cycles must be non-empty array';
  END IF;

  FOR c IN SELECT * FROM jsonb_array_elements(p_cycles)
  LOOP
    v_cycle:=v_cycle+1;
    v_ranked:=retail.r1f_rank_locations(c->'locations',p_policy);
    v_top:=v_ranked->0;

    SELECT count(*)::int
    INTO v_exploration_count
    FROM jsonb_array_elements(c->'locations') AS t(e)
    WHERE COALESCE(e#>>'{snapshot,sample_sufficiency}','INSUFFICIENT')
      ='INSUFFICIENT';

    SELECT e
    INTO l
    FROM jsonb_array_elements(c->'locations') AS t(e)
    WHERE e->>'location_code'=v_top->>'location_code'
    LIMIT 1;

    v_decision:=retail.r1f_recommendation_decision(
      jsonb_build_object(
        'opportunity_score',v_top->>'score',
        'sample_sufficiency',
          COALESCE(l#>>'{snapshot,sample_sufficiency}','INSUFFICIENT'),
        'location',COALESCE(l#>'{snapshot,location}','{}'::jsonb)
      ),
      p_policy
    );

    v_out:=v_out||jsonb_build_array(jsonb_build_object(
      'cycle',v_cycle,
      'top_location_code',v_top->>'location_code',
      'top_recommendation',v_decision->>'recommendation_type',
      'exploration_candidates',v_exploration_count,
      'exploration_retained',v_exploration_count>0
    ));
  END LOOP;

  RETURN v_out;
END $$;

-- ---------- FULL PIPELINE E2E FIXTURE AUTHORITY ------------------------------
CREATE TABLE retail.r1f_e2e_qa_scenarios(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scenario_code text NOT NULL UNIQUE,
  scenario_type text NOT NULL DEFAULT 'E2E'
    CHECK(scenario_type IN('E2E','CONCURRENCY')),
  job_ids uuid[] NOT NULL CHECK(cardinality(job_ids)>=2),
  intelligence_policy_id uuid NOT NULL
    REFERENCES retail.r1f_intelligence_policies(id) ON DELETE RESTRICT,
  window_end timestamptz NOT NULL,
  expected_top_location_fingerprint text,
  expected_minimum_facts integer NOT NULL DEFAULT 2 CHECK(expected_minimum_facts>=1),
  expected_minimum_snapshots integer NOT NULL DEFAULT 1 CHECK(expected_minimum_snapshots>=1),
  expected_minimum_recommendations integer NOT NULL DEFAULT 1 CHECK(expected_minimum_recommendations>=1),
  fixture_sha256 text NOT NULL CHECK(fixture_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(intelligence_policy_id,window_end)
);

CREATE OR REPLACE FUNCTION retail.r1f_e2e_scenario_document(
  p_row retail.r1f_e2e_qa_scenarios
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT
AS $$
  SELECT jsonb_build_object(
    'scenario_code',p_row.scenario_code,
    'scenario_type',p_row.scenario_type,
    'job_ids',to_jsonb(p_row.job_ids),
    'intelligence_policy_id',p_row.intelligence_policy_id,
    'window_end',p_row.window_end,
    'expected_top_location_fingerprint',
      p_row.expected_top_location_fingerprint,
    'expected_minimum_facts',p_row.expected_minimum_facts,
    'expected_minimum_snapshots',p_row.expected_minimum_snapshots,
    'expected_minimum_recommendations',
      p_row.expected_minimum_recommendations
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1f_prepare_e2e_scenario()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.fixture_sha256:=retail.r1f_sha256_jsonb(
    retail.r1f_e2e_scenario_document(NEW)
  );
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_prepare_e2e_scenario
BEFORE INSERT OR UPDATE ON retail.r1f_e2e_qa_scenarios
FOR EACH ROW EXECUTE FUNCTION retail.r1f_prepare_e2e_scenario();

CREATE OR REPLACE FUNCTION retail.r1f_e2e_scenario_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1F V2 E2E scenarios cannot be deleted';
  END IF;

  IF OLD.active=true THEN
    IF (to_jsonb(NEW)-ARRAY['active'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['active']) THEN
      RAISE EXCEPTION 'Active R1F V2 E2E scenario immutable';
    END IF;
  ELSIF NEW.active<>OLD.active THEN
    RAISE EXCEPTION 'Inactive R1F V2 E2E scenario cannot be reactivated';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_e2e_scenario_guard
BEFORE UPDATE OR DELETE ON retail.r1f_e2e_qa_scenarios
FOR EACH ROW EXECUTE FUNCTION retail.r1f_e2e_scenario_guard();

-- ---------- V2 CERTIFICATION POLICY -----------------------------------------
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
     OR COALESCE((p_policy->>'minimum_local_timezone_coverage_pct')::numeric,-1)<95 THEN
    RAISE EXCEPTION 'R1F V2 certification policy weaker than Green Tier 1';
  END IF;

  IF jsonb_typeof(COALESCE(p_policy->'class_minimums','{}'::jsonb))<>'object' THEN
    RAISE EXCEPTION 'R1F V2 class_minimums must be object';
  END IF;

  FOR v_class IN SELECT jsonb_object_keys(v_required)
  LOOP
    IF COALESCE(
      (p_policy#>>ARRAY['class_minimums',v_class])::int,0
    ) < (v_required->>v_class)::int THEN
      RAISE EXCEPTION
        'R1F V2 class % minimum below Green Tier floor %',
        v_class,(v_required->>v_class)::int;
    END IF;
  END LOOP;
END $$;

ALTER TABLE retail.r1f_certification_runs
  ADD COLUMN e2e_results jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN e2e_manifest_sha256 text,
  ADD COLUMN ranking_results jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN convergence_results jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN concurrency_results jsonb NOT NULL DEFAULT '{}'::jsonb;


CREATE OR REPLACE FUNCTION retail.r1f_r1e_identity_is_current(
  p_certification_run_id uuid,
  p_package_sha256 text
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      b.r1e_certification_run_id=p_certification_run_id
      AND b.r1e_package_sha256=p_package_sha256
      AND retail.r1f_r1e_binding_is_current()=true
    FROM retail.r1f_r1e_certification_binding b
    WHERE b.singleton=true
  ),false)
$$;

CREATE OR REPLACE FUNCTION retail.r1f_compilation_identity_is_current(
  p_compilation_id uuid,
  p_target_id uuid,
  p_r1a_revision_id uuid,
  p_r1a_revision_hash text,
  p_platform_id uuid,
  p_location_fingerprint text
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT EXISTS(
    SELECT 1
    FROM retail.effective_compiled_search_jobs ec
    WHERE ec.id=p_compilation_id
      AND ec.target_id=p_target_id
      AND ec.r1a_revision_id=p_r1a_revision_id
      AND ec.r1a_revision_hash=p_r1a_revision_hash
      AND ec.platform_id=p_platform_id
      AND retail.r1f_sha256_jsonb(
        COALESCE(ec.normalized_job_json->'location','{}'::jsonb)
      )=p_location_fingerprint
  )
$$;

-- ---------- V2 CURRENTNESS / FINAL OUTPUT -----------------------------------
CREATE OR REPLACE FUNCTION retail.r1f_latest_certification_is_current()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      cr.certification_status='CERTIFIED'
      AND cr.certification_version='r1f-v2.0.0'
      AND retail.r1f_r1e_identity_is_current(
            cr.r1e_certification_run_id,
            cr.r1e_package_sha256
          )=true
      AND p.certification_status='certified'
      AND cr.policy_id=p.id
      AND cr.policy_sha256=p.policy_sha256
      AND p.policy_sha256=retail.r1f_sha256_jsonb(p.policy_json)
      AND cp.certification_status='certified'
      AND cr.certification_policy_id=cp.id
      AND cr.certification_policy_sha256=cp.policy_sha256
      AND cp.policy_sha256=retail.r1f_sha256_jsonb(cp.policy_json)
      AND cr.e2e_manifest_sha256 IS NOT NULL
      AND COALESCE((cr.e2e_results->>'allPassed')::boolean,false)=true
      AND COALESCE((cr.ranking_results->>'allPassed')::boolean,false)=true
      AND COALESCE((cr.convergence_results->>'allPassed')::boolean,false)=true
      AND COALESCE((cr.concurrency_results->>'allPassed')::boolean,false)=true
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

CREATE OR REPLACE VIEW retail.r1f_effective_search_recommendations AS
SELECT r.*
FROM retail.r1f_search_recommendations r
JOIN retail.r1f_intelligence_policies p ON p.id=r.policy_id
JOIN retail.r1f_r1e_certification_binding b
  ON b.singleton=true
 AND b.r1e_certification_run_id=r.r1e_certification_run_id
WHERE r.status='PROPOSED'
  AND r.certification_fixture=false
  AND r.engine_version='r1f-v2.0.0'
  AND r.expires_at>now()
  AND p.certification_status='certified'
  AND p.policy_sha256=r.policy_sha256
  AND p.policy_sha256=retail.r1f_sha256_jsonb(p.policy_json)
  AND r.recommendation_sha256=
      retail.r1f_sha256_jsonb(r.recommendation_document)
  AND retail.r1f_r1e_binding_is_current()=true
  AND retail.r1f_latest_certification_is_current()=true
  AND retail.r1f_compilation_identity_is_current(
        r.compilation_id,
        r.target_id,
        r.r1a_revision_id,
        r.r1a_revision_hash,
        r.platform_id,
        r.location_fingerprint
      )=true
  AND (
    r.recommendation_type<>'EXPAND_GEO_CHILDREN'
    OR (
      cardinality(COALESCE(
        r.recommended_child_compilation_ids,
        ARRAY[]::uuid[]
      ))>0
      AND NOT EXISTS(
        SELECT 1
        FROM unnest(r.recommended_child_compilation_ids) child_id
        WHERE NOT EXISTS(
          SELECT 1
          FROM retail.effective_compiled_search_jobs ec2
          WHERE ec2.id=child_id
            AND ec2.target_id=r.target_id
            AND ec2.r1a_revision_id=r.r1a_revision_id
            AND ec2.r1a_revision_hash=r.r1a_revision_hash
            AND ec2.platform_id=r.platform_id
        )
      )
    )
  );


CREATE TRIGGER trg_r1f_audit_e2e_scenarios
AFTER INSERT OR UPDATE OR DELETE ON retail.r1f_e2e_qa_scenarios
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1f_log_retail_change();

DROP TRIGGER IF EXISTS trg_r1f_certification_insert_guard
ON retail.r1f_certification_runs;

CREATE OR REPLACE FUNCTION retail.r1f_v2_certification_insert_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.certification_version<>'r1f-v2.0.0' THEN
    RAISE EXCEPTION 'R1F V2 unsupported certification version %',
      NEW.certification_version;
  END IF;

  IF NEW.r1f_package_sha256 !~ '^[0-9a-f]{64}$'
     OR NEW.r1e_package_sha256 !~ '^[0-9a-f]{64}$'
     OR NEW.evidence_manifest_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R1F V2 certification SHA format invalid';
  END IF;

  IF NEW.certification_status='CERTIFIED' THEN

    IF NEW.failed_gates<>0
       OR NEW.passed_gates<>NEW.total_gates THEN
      RAISE EXCEPTION 'R1F V2 CERTIFIED requires every gate to pass';
    END IF;

    IF NEW.e2e_manifest_sha256 IS NULL
       OR NEW.e2e_manifest_sha256 !~ '^[0-9a-f]{64}$'
       OR COALESCE((NEW.e2e_results->>'allPassed')::boolean,false) IS NOT TRUE
       OR COALESCE((NEW.ranking_results->>'allPassed')::boolean,false) IS NOT TRUE
       OR COALESCE((NEW.convergence_results->>'allPassed')::boolean,false) IS NOT TRUE
       OR COALESCE((NEW.concurrency_results->>'allPassed')::boolean,false) IS NOT TRUE THEN
      RAISE EXCEPTION
        'R1F V2 certification requires E2E/ranking/convergence/concurrency evidence';
    END IF;

    IF retail.r1f_r1e_binding_is_current() IS NOT TRUE THEN
      RAISE EXCEPTION 'R1F V2 certification requires current R1E binding';
    END IF;

    IF NOT EXISTS(
      SELECT 1
      FROM retail.r1f_intelligence_policies p
      WHERE p.id=NEW.policy_id
        AND p.certification_status='certified'
        AND p.policy_sha256=NEW.policy_sha256
        AND p.policy_sha256=retail.r1f_sha256_jsonb(p.policy_json)
    ) THEN
      RAISE EXCEPTION 'R1F V2 intelligence policy identity invalid';
    END IF;

    IF NOT EXISTS(
      SELECT 1
      FROM retail.r1f_certification_policies cp
      WHERE cp.id=NEW.certification_policy_id
        AND cp.certification_status='certified'
        AND cp.policy_sha256=NEW.certification_policy_sha256
        AND cp.policy_sha256=retail.r1f_sha256_jsonb(cp.policy_json)
    ) THEN
      RAISE EXCEPTION 'R1F V2 certification policy identity invalid';
    END IF;

    IF NOT EXISTS(
      SELECT 1
      FROM retail.r1f_r1e_certification_binding b
      WHERE b.singleton=true
        AND b.r1e_certification_run_id=NEW.r1e_certification_run_id
        AND b.r1e_package_sha256=NEW.r1e_package_sha256
    ) THEN
      RAISE EXCEPTION 'R1F V2 upstream R1E identity mismatch';
    END IF;
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1f_v2_certification_insert_guard
BEFORE INSERT ON retail.r1f_certification_runs
FOR EACH ROW EXECUTE FUNCTION retail.r1f_v2_certification_insert_guard();

-- ---------- PRIVILEGES -------------------------------------------------------
REVOKE ALL ON FUNCTION retail.r1f_ingest_completed_job_v2(
  uuid,uuid,text,text,boolean,uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1f_build_intelligence_v2(
  uuid,timestamptz,uuid,text,text,boolean,uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1f_generate_recommendations_v2(
  uuid,timestamptz,uuid,text,text,boolean,uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION retail.r1f_ingest_completed_job_v2(
  uuid,uuid,text,text,boolean,uuid
) TO retail_r1f_worker,retail_r1f_certifier;
GRANT EXECUTE ON FUNCTION retail.r1f_build_intelligence_v2(
  uuid,timestamptz,uuid,text,text,boolean,uuid
) TO retail_r1f_worker,retail_r1f_certifier;
GRANT EXECUTE ON FUNCTION retail.r1f_generate_recommendations_v2(
  uuid,timestamptz,uuid,text,text,boolean,uuid
) TO retail_r1f_worker,retail_r1f_certifier;

GRANT SELECT ON retail.r1f_local_temporal_search_intelligence
  TO retail_r1f_reader;

COMMIT;
