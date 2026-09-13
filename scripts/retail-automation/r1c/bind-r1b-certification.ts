import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [certRunId,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1C_CERTIFIER||'R1C Upstream Binder';
if(!certRunId){
  throw new Error('usage: tsx bind-r1b-certification.ts <r1b_certification_run_uuid> [actor]');
}

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1C_R1B_REBIND','user',actor,actor,
    'retail.r1c_r1b_certification_binding'
  );
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','user',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[actor]);
    await c.query(`select set_config('app.process_run_id',$1,true)`,[run.runId]);
    await c.query(`select set_config('app.correlation_id',$1,true)`,[run.correlationId]);

    await c.query(`
      select retail.r1c_bind_r1b_certification($1,$2,$3,$4)
    `,[certRunId,run.runId,run.correlationId,actor]);

    const ok=await c.query(`select retail.r1c_r1b_binding_is_current() ok`);
    if(ok.rows[0]?.ok!==true){
      throw new Error('R1B V4 binding did not become current');
    }

    await c.query('commit');
    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});

    console.log(JSON.stringify({
      event:'r1c_r1b_v4_binding_created',
      r1bCertificationRunId:certRunId,
      processRunId:run.runId,
      correlationId:run.correlationId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e);
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
