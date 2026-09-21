BEGIN;

CREATE OR REPLACE FUNCTION retail.r1f_ingest_completed_job_v2(p_job_id uuid, p_process_run_id uuid, p_correlation_id text, p_actor text, p_certification_fixture boolean DEFAULT false, p_certification_batch_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'retail', 'arb'
AS $function$
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

  v_cost_basis:=a.cost_basis;
  IF v_cost_basis NOT IN ('actual','estimated') THEN
    RAISE EXCEPTION
      'R1F V2 authoritative attempt cost_basis required';
  END IF;

  v_cost:=COALESCE(a.actual_cost_usd,j.estimated_cost_usd);
  IF v_cost IS NULL OR v_cost<0 THEN
    RAISE EXCEPTION 'R1F V2 valid job cost required';
  END IF;

  v_records_requested:=retail.r1f_try_integer(
    a.metrics_json->>'records_requested'
  );

  -- JSON null is distinct from SQL NULL and must not reach the object constraint.
  v_location:=CASE
    WHEN jsonb_typeof(comp.normalized_job_json->'location')='object'
      THEN comp.normalized_job_json->'location'
    ELSE '{}'::jsonb
  END;
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
END $function$;

COMMIT;
