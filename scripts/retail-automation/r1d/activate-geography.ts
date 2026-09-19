import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [parentCompilationId,signalType,scoreArg,maxChildrenArg,reasonArg,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1D_ACTOR_NAME||'R1D Geo Escalation';
const score=scoreArg?Number(scoreArg):null;
const maxChildren=Number(maxChildrenArg??'10');

if(!parentCompilationId||!signalType){
  throw new Error(
    'usage: tsx activate-geography.ts <parent_compilation_uuid> <signal_type> [score] [max_children] [reason] [actor]'
  );
}
if(!Number.isInteger(maxChildren)||maxChildren<1||maxChildren>100){
  throw new Error('max_children must be integer 1..100');
}

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1D_GEO_ACTIVATE','service_account',
    'r1d-geo',actor,'retail.r1d_compilation_schedule_state'
  );
  try{
    const r=await pool.query(`
      select retail.r1d_activate_geo_children(
        $1,$2,$3,$4,$5,$6,$7,$8
      ) activated
    `,[
      parentCompilationId,signalType,score,
      reasonArg??null,maxChildren,actor,
      run.runId,run.correlationId
    ]);
    const n=Number(r.rows[0].activated);
    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:n,succeeded:n,failed:0}
    );
    console.log(JSON.stringify({
      event:'r1d_geo_children_activated',
      parentCompilationId,signalType,score,maxChildren,
      activated:n,processRunId:run.runId
    },null,2));
  }catch(e){
    await finishPersistentRun(pool,run.runId,'FAILED',{},e);
    throw e;
  }finally{
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
