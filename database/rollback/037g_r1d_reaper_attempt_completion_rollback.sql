BEGIN;

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

COMMIT;
