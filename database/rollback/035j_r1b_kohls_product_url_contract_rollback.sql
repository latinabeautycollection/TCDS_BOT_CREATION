BEGIN;

SELECT set_config('tcds.code_version', :'code_version', true);

DO $$
DECLARE
  adapter_row record;
  process_run_id uuid;
  correlation_id text := gen_random_uuid()::text;
BEGIN
  SELECT
    a.id AS adapter_id,
    a.platform_id,
    a.scraper_asset_id,
    a.certification_status AS adapter_status,
    c.id AS contract_id,
    c.certification_status AS contract_status
  INTO adapter_row
  FROM retail.retail_search_adapters a
  JOIN retail.retail_scraper_contracts c
    ON c.id = a.scraper_contract_id
   AND c.adapter_id = a.id
  WHERE a.adapter_code = 'kohls_brightdata_product_url'
    AND a.adapter_version = '1';

  IF NOT FOUND THEN
    RAISE NOTICE 'Kohls product-URL authority is not installed';
    RETURN;
  END IF;

  IF adapter_row.scraper_asset_id <>
     'dbcba440-320f-41e8-bbd2-96cf4d8bd339'::uuid THEN
    RAISE EXCEPTION 'Kohls adapter asset changed; rollback refused';
  END IF;

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
    'r1b-kohls-url-rollback', 'r1b-v4-kohls-1',
    current_setting('tcds.code_version'),
    'r1b-v4.0.0',
    'retail.retail_scraper_contracts',
    'R1B:KOHLS:PRODUCT_URL:ROLLBACK:' || correlation_id
  )
  RETURNING run_id INTO process_run_id;

  IF adapter_row.contract_status NOT IN ('blocked', 'retired') THEN
    PERFORM retail.r1b_transition_scraper_contract(
      adapter_row.contract_id,
      'blocked',
      process_run_id,
      correlation_id,
      'tictac',
      'Kohls product-URL authority production rollback'
    );
  END IF;

  PERFORM set_config('app.actor_type', 'user', true);
  PERFORM set_config('app.actor_name', 'tictac', true);
  PERFORM set_config(
    'app.process_run_id', process_run_id::text, true
  );
  PERFORM set_config(
    'app.correlation_id', correlation_id, true
  );

  UPDATE retail.retail_search_adapters
  SET certification_status = 'suspended',
      suspended_reason =
        'Kohls product-URL authority production rollback',
      updated_at = now()
  WHERE id = adapter_row.adapter_id
    AND certification_status <> 'suspended';

  UPDATE retail.r1b_adapter_integration_matrix
  SET adapter_id = NULL,
      scraper_contract_id = NULL,
      r1b_certification_status = 'inventory_pending',
      updated_at = now()
  WHERE platform_id = adapter_row.platform_id
    AND (
      adapter_id = adapter_row.adapter_id
      OR scraper_contract_id = adapter_row.contract_id
    );

  UPDATE arb.process_runs
  SET status = 'SUCCEEDED',
      rows_seen = 1,
      rows_succeeded = 1,
      rows_failed = 0,
      completed_at = now(),
      updated_at = now()
  WHERE run_id = process_run_id;

  RAISE NOTICE
    'Kohls adapter % and contract % blocked',
    adapter_row.adapter_id,
    adapter_row.contract_id;
END
$$;

COMMIT;
