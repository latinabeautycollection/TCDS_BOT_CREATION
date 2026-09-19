BEGIN;
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
COMMIT;
