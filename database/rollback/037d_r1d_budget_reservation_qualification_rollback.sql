BEGIN;
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
COMMIT;
