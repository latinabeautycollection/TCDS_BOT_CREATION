import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const limit=Number(process.env.R1D_MATERIALIZE_LIMIT??'500');
const actor=process.env.R1D_ACTOR_NAME||'R1D Scheduler';

if(!Number.isInteger(limit)||limit<1||limit>10000){
  throw new Error('R1D_MATERIALIZE_LIMIT must be integer 1..10000');
}

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1D_MATERIALIZE','service_account',
    'r1d-scheduler',actor,'retail.r1d_dispatch_jobs'
  );
  try{
    const r=await pool.query(`
      select retail.r1d_materialize_due_jobs_v2(
        now(),$1,$2,$3,$4
      ) materialized
    `,[limit,run.runId,run.correlationId,actor]);

    const n=Number(r.rows[0].materialized);
    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:n,succeeded:n,failed:0}
    );

    console.log(JSON.stringify({
      event:'r1d_due_jobs_materialized',
      materialized:n,
      processRunId:run.runId,
      correlationId:run.correlationId
    },null,2));
  }catch(e){
    await finishPersistentRun(pool,run.runId,'FAILED',{},e);
    throw e;
  }finally{
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
