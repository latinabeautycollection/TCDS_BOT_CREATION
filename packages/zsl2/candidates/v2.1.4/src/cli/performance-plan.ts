import {pool} from '../repositories/db.js';
const run=process.argv[2];if(!run)throw new Error('USAGE: performance-plan <normalization_run_uuid>');
const p=pool(),c=await p.connect();try{
 const q=await c.query(`select source_key,count(*)::text pages,round(avg(duration_ms),3)::text avg_ms,round(percentile_cont(0.50) within group(order by duration_ms)::numeric,3)::text p50_ms,round(percentile_cont(0.95) within group(order by duration_ms)::numeric,3)::text p95_ms,round(percentile_cont(0.99) within group(order by duration_ms)::numeric,3)::text p99_ms,round(max(duration_ms),3)::text max_ms,sum(rows_affected)::text rows from zsl.zsl2_performance_measurements where normalization_run_id=$1 and operation='NORMALIZE_PAGE' group by source_key order by source_key`,[run]);
 console.log(JSON.stringify({run,sources:q.rows,thresholds:{p99PageMs:60000,maxStatementMs:120000}},null,2));
}finally{c.release();await p.end();}
