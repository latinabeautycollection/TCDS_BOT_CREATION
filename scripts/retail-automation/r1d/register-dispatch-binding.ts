import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [adapterId,configFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1D_CERTIFIER||'R1D Dispatch Binding Registrar';

if(!adapterId||!configFile){
  throw new Error(
    'usage: tsx register-dispatch-binding.ts <adapter_uuid> <binding.json> [actor]'
  );
}

async function main(){
  const cfg=JSON.parse(await readFile(configFile,'utf8'));

  const run=await startPersistentRun(
    pool,'RETAIL_R1D_BINDING_CERTIFY','user',actor,actor,
    'retail.r1d_dispatch_bindings'
  );
  const c=await pool.connect();

  try{
    await c.query('begin');

    const r=await c.query(`
      select retail.r1d_register_dispatch_binding(
        $1,$2,$3,$4,$5,$6,$7::jsonb,$8
      ) id
    `,[
      adapterId,
      cfg.runner_kind,
      cfg.npm_script??null,
      cfg.payload_delivery,
      cfg.timeout_seconds??900,
      cfg.max_concurrency??1,
      JSON.stringify(cfg.runner_policy_json??{}),
      actor
    ]);

    await c.query('commit');
    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:1,succeeded:1,failed:0}
    );

    console.log(JSON.stringify({
      event:'r1d_dispatch_binding_registered',
      bindingId:r.rows[0].id,
      adapterId,
      processRunId:run.runId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(
      pool,run.runId,'FAILED',
      {seen:1,succeeded:0,failed:1},e
    );
    throw e;
  }finally{
    c.release();await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
