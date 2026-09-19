import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const actor=process.env.R1D_ACTOR_NAME||'R1D Lease Reaper';

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1D_LEASE_REAP','service_account',
    'r1d-reaper',actor,'retail.r1d_dispatch_jobs'
  );
  try{
    const r=await pool.query(`
      select retail.r1d_reap_expired_leases(
        now(),$1,$2
      ) reaped
    `,[run.runId,run.correlationId]);

    const n=Number(r.rows[0].reaped);
    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:n,succeeded:n,failed:0}
    );
    console.log(JSON.stringify({
      event:'r1d_expired_leases_reaped',
      reaped:n,processRunId:run.runId
    },null,2));
  }catch(e){
    await finishPersistentRun(pool,run.runId,'FAILED',{},e);
    throw e;
  }finally{
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
