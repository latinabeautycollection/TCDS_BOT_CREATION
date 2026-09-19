BEGIN;

CREATE OR REPLACE FUNCTION retail.r1d_mark_r1e_qa_captures(
  p_job_id uuid,
  p_collection_run_id uuid
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  v_job retail.r1d_dispatch_jobs%ROWTYPE;
  v_attempt_id bigint;
  v_attempt_job_id uuid;
  v_attempt_count integer;
  v_marked integer;
BEGIN
  SELECT * INTO v_job
  FROM retail.r1d_dispatch_jobs
  WHERE id=p_job_id;

  IF NOT FOUND
     OR v_job.certification_fixture IS NOT TRUE
     OR v_job.status<>'succeeded' THEN
    RAISE EXCEPTION 'R1E QA marking requires a succeeded certification job';
  END IF;

  SELECT count(*)::integer,min(a.id),min(a.job_id::text)::uuid
  INTO v_attempt_count,v_attempt_id,v_attempt_job_id
  FROM retail.r1d_dispatch_attempts a
  JOIN retail.r1d_dispatch_jobs claimed_job
    ON claimed_job.id=a.job_id
   AND claimed_job.status='succeeded'
  WHERE a.success=true
    AND a.metrics_json->>'collection_run_id'=p_collection_run_id::text;

  IF v_attempt_count<>1 OR v_attempt_job_id IS DISTINCT FROM p_job_id THEN
    RAISE EXCEPTION
      'R1E QA marking requires one unambiguous successful attempt for this job';
  END IF;

  IF NOT EXISTS(
    SELECT 1
    FROM retail.collection_runs cr
    WHERE cr.id=p_collection_run_id
      AND cr.platform_id=v_job.platform_id
  ) THEN
    RAISE EXCEPTION 'R1E QA collection run missing or platform mismatch';
  END IF;

  UPDATE retail.raw_product_captures capture
  SET capture_metadata=COALESCE(capture.capture_metadata,'{}'::jsonb) ||
      jsonb_build_object(
        'r1e_qa_fixture',true,
        'r1d_job_id',p_job_id,
        'r1d_attempt_id',v_attempt_id,
        'r1d_collection_run_id',p_collection_run_id
      )
  WHERE capture.collection_run_id=p_collection_run_id
    AND capture.platform_id=v_job.platform_id;

  GET DIAGNOSTICS v_marked=ROW_COUNT;
  IF v_marked=0 THEN
    RAISE EXCEPTION 'R1E QA collection run contains no raw captures';
  END IF;

  RETURN v_marked;
END $$;

REVOKE ALL ON FUNCTION retail.r1d_mark_r1e_qa_captures(uuid,uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION retail.r1d_mark_r1e_qa_captures(uuid,uuid)
TO retail_r1d_dispatcher;

COMMIT;
