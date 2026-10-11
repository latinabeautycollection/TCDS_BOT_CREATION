\set ON_ERROR_STOP on
-- Run in staging after a representative replay. This does not change performance thresholds.
SELECT source_key,operation,count(*) AS samples,
       round(percentile_cont(0.50) within group(order by duration_ms)::numeric,3) AS p50_ms,
       round(percentile_cont(0.95) within group(order by duration_ms)::numeric,3) AS p95_ms,
       round(percentile_cont(0.99) within group(order by duration_ms)::numeric,3) AS p99_ms,
       round(max(duration_ms)::numeric,3) AS max_ms,
       sum(rows_affected) AS rows_affected
FROM zsl.zsl2_performance_measurements
WHERE normalization_run_id=:'run_id'::uuid
GROUP BY source_key,operation
ORDER BY source_key,operation;

-- Page policy gate: unchanged from V2.1.2.
WITH p AS (
 SELECT percentile_cont(0.99) within group(order by duration_ms) AS p99_ms,
        max(duration_ms) AS max_ms
 FROM zsl.zsl2_performance_measurements
 WHERE normalization_run_id=:'run_id'::uuid AND operation='NORMALIZE_PAGE'
)
SELECT p99_ms,max_ms,(p99_ms < 60000 AND max_ms < 120000) AS performance_policy_pass FROM p;
