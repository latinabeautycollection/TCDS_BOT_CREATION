import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [bindingId,evidenceFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1D_CERTIFIER;

if(!bindingId||!evidenceFile||!actor){
  throw new Error(
    'usage: tsx certify-dispatch-binding.ts <binding_uuid> <evidence.json> <certifier>'
  );
}

async function main(){
  const evidence=JSON.parse(await readFile(evidenceFile,'utf8'));

  const run=await startPersistentRun(
    pool,'RETAIL_R1D_BINDING_CERTIFY','user',actor,actor,
    'retail.r1d_dispatch_bindings'
  );
  const c=await pool.connect();

  try{
    await c.query('begin');
    await c.query(`
      select retail.r1d_certify_dispatch_binding(
        $1,$2::jsonb,$3
      )
    `,[bindingId,JSON.stringify(evidence),actor]);

    const q=await c.query(`
      select * from retail.r1d_dispatch_bindings where id=$1
    `,[bindingId]);

    await c.query('commit');
    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:1,succeeded:1,failed:0}
    );

    console.log(JSON.stringify({
      event:'r1d_dispatch_binding_certified',
      binding:q.rows[0],
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
