import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [routeId,profileId,compilerId]=process.argv.slice(2);
if(!routeId||!profileId||!compilerId){
  throw new Error('usage: tsx compile-route.ts <route_uuid> <profile_uuid> <compiler_uuid>');
}
const actor=process.env.R1C_ACTOR_NAME||'R1C Compiler Service';

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1C_COMPILE_ROUTE','service_account',
    'r1c-compiler',actor,'retail.search_route_bindings'
  );

  const c=await pool.connect();
  try{
    await c.query('begin');
    const r=await c.query(`
      select retail.r1c_compile_route($1,$2,$3,$4,$5,$6) compilation_id
    `,[
      routeId,profileId,compilerId,
      run.runId,run.correlationId,actor
    ]);

    await c.query('commit');
    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});

    console.log(JSON.stringify({
      event:'r1c_v3_route_compiled',
      compilationId:r.rows[0].compilation_id,
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
