BEGIN;

INSERT INTO arb.process_registry(
  process_name,
  phase_no,
  process_group,
  description,
  owner_team,
  active_flag
)
VALUES(
  'RETAIL_R1B_ADAPTER_SUPERSEDE',
  2,
  'RETAIL_AUTOMATION',
  'Retire routes and suspend an adapter superseded by certified scraper authority.',
  'TCDS Retail Automation',
  true
)
ON CONFLICT(process_name) DO NOTHING;

DO $$
DECLARE
  v_old_adapter_id uuid;
  v_new_adapter_id uuid;
  v_run_id uuid;
  v_correlation_id uuid := gen_random_uuid();
  v_retired_routes integer;
BEGIN
  SELECT id INTO STRICT v_old_adapter_id
  FROM retail.retail_search_adapters
  WHERE adapter_code='bestbuy_brightdata_search'
    AND adapter_version='2';

  SELECT id INTO STRICT v_new_adapter_id
  FROM retail.retail_search_adapters
  WHERE adapter_code='bestbuy_brightdata_search'
    AND adapter_version='3';

  IF retail.r1b_adapter_execution_ready(v_new_adapter_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Best Buy adapter v3 is not execution-ready';
  END IF;

  INSERT INTO arb.process_runs(
    process_name,
    process_stage,
    status,
    correlation_id,
    actor_type,
    actor_id,
    actor_name,
    worker_name,
    worker_instance_id,
    code_version,
    ruleset_version,
    entity_type,
    idempotency_key
  )
  VALUES(
    'RETAIL_R1B_ADAPTER_SUPERSEDE',
    'EXECUTE',
    'STARTED',
    v_correlation_id,
    'user',
    'tictac',
    'Tictac R1B V4 Authority',
    'r1b-adapter-supersede',
    'r1b-v4-bestbuy',
    current_setting('app.code_version', true),
    'r1b-v4.0.0',
    'retail.search_route_bindings',
    'R1B_BESTBUY_V2_SUPERSEDE:' || v_correlation_id::text
  )
  RETURNING run_id INTO v_run_id;

  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id','tictac',true);
  PERFORM set_config('app.actor_name','Tictac R1B V4 Authority',true);
  PERFORM set_config('app.process_run_id',v_run_id::text,true);
  PERFORM set_config('app.correlation_id',v_correlation_id::text,true);

  UPDATE retail.search_route_bindings old_route
  SET
    route_status='retired',
    source_process_run_id=v_run_id,
    source_correlation_id=v_correlation_id::text
  WHERE old_route.adapter_id=v_old_adapter_id
    AND old_route.route_status='approved'
    AND EXISTS(
      SELECT 1
      FROM retail.search_route_bindings new_route
      WHERE new_route.adapter_id=v_new_adapter_id
        AND new_route.route_status='approved'
        AND new_route.target_id=old_route.target_id
        AND new_route.r1a_revision_id=old_route.r1a_revision_id
        AND new_route.collection_source_id=old_route.collection_source_id
        AND new_route.location_id IS NOT DISTINCT FROM old_route.location_id
        AND retail.r1b_route_is_current(new_route.id)=true
    );

  GET DIAGNOSTICS v_retired_routes = ROW_COUNT;

  IF v_retired_routes <> 9 THEN
    RAISE EXCEPTION
      'Expected to retire 9 superseded routes; retired %',
      v_retired_routes;
  END IF;

  UPDATE retail.retail_search_adapters
  SET
    certification_status='suspended',
    suspended_reason='Superseded by execution-ready Best Buy adapter v3'
  WHERE id=v_old_adapter_id
    AND certification_status='certified_dynamic_search';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Best Buy adapter v2 was not suspended';
  END IF;

  UPDATE arb.process_runs
  SET
    status='SUCCEEDED',
    rows_seen=v_retired_routes + 1,
    rows_succeeded=v_retired_routes + 1,
    rows_failed=0,
    completed_at=now(),
    updated_at=now()
  WHERE run_id=v_run_id;
END
$$;

COMMIT;
