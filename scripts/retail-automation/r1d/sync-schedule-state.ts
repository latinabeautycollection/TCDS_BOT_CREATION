import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const actor=process.env.R1D_ACTOR_NAME||'R1D Scheduler';

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1D_SCHEDULE_SYNC','service_account',
    'r1d-scheduler',actor,'retail.r1d_compilation_schedule_state'
  );
  try{
    const r=await pool.query(`
      select retail.r1d_sync_schedule_state_v2(
        now(),$1,$2
      ) synchronized
    `,[run.runId,run.correlationId]);

    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:Number(r.rows[0].synchronized),succeeded:Number(r.rows[0].synchronized),failed:0}
    );
    console.log(JSON.stringify({
      event:'r1d_schedule_state_synchronized',
      synchronized:Number(r.rows[0].synchronized),
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
