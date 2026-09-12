import { Pool } from 'pg';
import { startRun,finishRun } from './provenance';
const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [routeId,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1B_APPROVER;
if(!routeId||!actor) throw new Error('usage: tsx approve-route.ts <route_uuid> <approver>');

async function main(){
  const c=await pool.connect();
  let runId:string|undefined;
  try{
    await c.query('begin');
    const run=await startRun(c,'RETAIL_R1B_ROUTE_APPROVE','user',actor,actor,'retail.search_route_bindings');
    runId=run.runId;
    await c.query(`select retail.r1b_approve_route($1,$2,$3,$4)`,[routeId,actor,run.runId,run.correlationId]);
    await finishRun(c,run.runId,'SUCCEEDED');
    await c.query('commit');
    console.log(JSON.stringify({event:'r1b_route_approved',routeId,processRunId:run.runId,correlationId:run.correlationId},null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    if(runId){
      const d=await pool.connect();
      try{await finishRun(d,runId,'FAILED',e);}finally{d.release();}
    }
    throw e;
  }finally{c.release();await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
