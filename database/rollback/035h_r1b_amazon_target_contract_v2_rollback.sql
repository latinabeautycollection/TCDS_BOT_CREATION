BEGIN;

SELECT set_config(
  'tcds.code_version',
  :'code_version',
  true
);

DO $$
DECLARE
  adapter_record record;
  process_run_id uuid;
  correlation_id text;
BEGIN
  FOR adapter_record IN
    SELECT
      adapter.id AS adapter_id,
      adapter.scraper_contract_id,
      adapter.adapter_code
    FROM retail.retail_search_adapters adapter
    WHERE adapter.adapter_code IN (
      'amazon_brightdata_search',
      'target_brightdata_search'
    )
      AND adapter.adapter_version = '2'
  LOOP
    IF adapter_record.scraper_contract_id IS NOT NULL
       AND EXISTS (
         SELECT 1
         FROM retail.retail_scraper_contracts contract
         WHERE contract.id = adapter_record.scraper_contract_id
           AND contract.certification_status NOT IN (
             'blocked',
             'retired'
           )
       )
    THEN
      correlation_id := gen_random_uuid()::text;

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
      VALUES (
        'RETAIL_R1B_SCRAPER_CONTRACT_BLOCK',
        'EXECUTE',
        'STARTED',
        correlation_id,
        'user',
        'tictac',
        'Tictac R1B Contract V2 Rollback',
        'r1b-amazon-target-contract-v2-rollback',
        'r1b-v4-2',
        current_setting('tcds.code_version'),
        'r1b-v4.0.0',
        'retail.retail_scraper_contracts',
        'R1B:CONTRACT:BLOCK:' ||
          adapter_record.adapter_code || ':' ||
          correlation_id
      )
      RETURNING run_id INTO process_run_id;

      PERFORM retail.r1b_transition_scraper_contract(
        adapter_record.scraper_contract_id,
        'blocked',
        process_run_id,
        correlation_id,
        'Tictac R1B Contract V2 Rollback',
        'Amazon/Target V2 contract rollback'
      );

      UPDATE arb.process_runs
      SET status = 'SUCCEEDED',
          rows_seen = 1,
          rows_succeeded = 1,
          rows_failed = 0,
          completed_at = now(),
          updated_at = now()
      WHERE run_id = process_run_id;
    END IF;

    UPDATE retail.retail_search_adapters
    SET certification_status = 'suspended',
        suspended_reason =
          'Amazon/Target V2 contract rolled back'
    WHERE id = adapter_record.adapter_id
      AND certification_status <> 'retired';
  END LOOP;
END
$$;

COMMIT;
