import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [certRunId,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1E_CERTIFIER||'R1E Upstream Binder';

if(!certRunId){
  throw new Error('usage: tsx bind-r1d-certification.ts <latest_r1d_v2_certification_uuid> [actor]');
}

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1E_R1D_BIND','user',actor,actor,
    'retail.r1e_r1d_certification_binding'
  );
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`
      select retail.r1e_bind_r1d_certification_v2($1,$2,$3,$4)
    `,[certRunId,run.runId,run.correlationId,actor]);

    const ok=await c.query(`select retail.r1e_r1d_binding_is_current() ok`);
    if(ok.rows[0]?.ok!==true){
      throw new Error('R1D V2 binding did not become current');
    }

    await c.query('commit');
    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});

    console.log(JSON.stringify({
      event:'r1e_v2_r1d_binding_created',
      r1dCertificationRunId:certRunId,
      processRunId:run.runId,
      correlationId:run.correlationId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e);
    throw e;
  }finally{
    c.release();await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
