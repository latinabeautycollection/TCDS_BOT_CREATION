BEGIN;

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

  -- Budget history is append-only. Claim V2 supplies provenance when the
  -- reservation is inserted, so historical ledger rows must never be updated.
END $$;

COMMIT;
