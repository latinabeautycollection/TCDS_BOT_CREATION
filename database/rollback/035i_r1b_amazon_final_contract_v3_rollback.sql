BEGIN;

SELECT set_config('tcds.code_version', :'code_version', true);

DO $$
DECLARE
  v3 record;
  rollback_run_id uuid;
  correlation_id text;
BEGIN
  SELECT
    a.id AS adapter_id,
    a.certification_status AS adapter_status,
    a.scraper_asset_id,
    c.id AS contract_id,
    c.certification_status AS contract_status
  INTO v3
  FROM retail.retail_search_adapters a
  JOIN retail.retail_scraper_contracts c
    ON c.id = a.scraper_contract_id
   AND c.adapter_id = a.id
  WHERE a.adapter_code = 'amazon_brightdata_search'
    AND a.adapter_version = '3';

  IF NOT FOUND THEN
    RAISE NOTICE 'Amazon V3 authority is not installed';
    RETURN;
  END IF;

  correlation_id := gen_random_uuid()::text;

  INSERT INTO arb.process_runs(
    process_name, process_stage, status, correlation_id,
    actor_type, actor_id, actor_name,
    worker_name, worker_instance_id, code_version,
    ruleset_version, entity_type, idempotency_key
  )
  VALUES (
    'RETAIL_R1B_SCRAPER_CONTRACT_BLOCK',
    'EXECUTE', 'STARTED', correlation_id,
    'user', 'tictac', 'Tictac',
    'r1b-amazon-v3-rollback', 'r1b-v4-3',
    current_setting('tcds.code_version'),
    'r1b-v4.0.0',
    'retail.retail_search_adapters',
    'R1B:AMAZON:V3:ROLLBACK:' || correlation_id
  )
  RETURNING run_id INTO rollback_run_id;

  IF v3.contract_status NOT IN ('blocked', 'retired') THEN
    PERFORM retail.r1b_transition_scraper_contract(
      v3.contract_id,
      'blocked',
      rollback_run_id,
      correlation_id,
      'tictac',
      'Amazon V3 production rollback'
    );
  END IF;

  PERFORM set_config('app.actor_type', 'user', true);
  PERFORM set_config('app.actor_name', 'tictac', true);
  PERFORM set_config(
    'app.process_run_id',
    rollback_run_id::text,
    true
  );
  PERFORM set_config(
    'app.correlation_id',
    correlation_id,
    true
  );

  UPDATE retail.retail_search_adapters
  SET certification_status = 'suspended',
      suspended_reason = 'Amazon V3 production rollback',
      updated_at = now()
  WHERE id = v3.adapter_id
    AND certification_status <> 'suspended';

  UPDATE retail.r1b_adapter_integration_matrix
  SET adapter_id = NULL,
      scraper_contract_id = NULL,
      r1b_certification_status = 'inventory_pending',
      updated_at = now()
  WHERE platform_code = 'amazon'
    AND (
      adapter_id = v3.adapter_id
      OR scraper_contract_id = v3.contract_id
    );

  UPDATE arb.process_runs
  SET status = 'SUCCEEDED',
      rows_seen = 1,
      rows_succeeded = 1,
      rows_failed = 0,
      completed_at = now(),
      updated_at = now()
  WHERE run_id = rollback_run_id;

  RAISE NOTICE
    'Amazon V3 adapter % and contract % blocked',
    v3.adapter_id,
    v3.contract_id;
END
$$;

COMMIT;
