import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [assetId,adapterId,contractFile,actorArg,supersedesArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1B_APPROVER||'R1B Scraper Contract Registrar';
if(!assetId||!adapterId||!contractFile){
  throw new Error('usage: tsx register-scraper-contract.ts <asset_uuid> <adapter_uuid> <contract.json> [actor] [supersedes_contract_uuid]');
}

async function createRun(processName:string){
  const correlationId=randomUUID();
  const r=await pool.query(`
    insert into arb.process_runs(
      process_name,process_stage,status,correlation_id,
      actor_type,actor_id,actor_name,
      worker_name,worker_instance_id,code_version,ruleset_version,
      entity_type,idempotency_key
    ) values(
      $1,'EXECUTE','STARTED',$2,'user',$3,$3,
      'r1b-scraper-contract-register',$4,$5,'r1b-v4.0.0',
      'retail.retail_scraper_contracts',$6
    ) returning run_id
  `,[processName,correlationId,actor,
     process.env.WORKER_INSTANCE_ID??'r1b-v4-1',
     process.env.CODE_VERSION??process.env.GIT_SHA??'unknown',
     `${processName}:${correlationId}`]);
  return {runId:r.rows[0].run_id,correlationId};
}

async function finishRun(runId:string,status:'SUCCEEDED'|'FAILED',err?:unknown){
  await pool.query(`
    update arb.process_runs
       set status=$2,
           completed_at=case when $2='SUCCEEDED' then now() else completed_at end,
           failed_at=case when $2='FAILED' then now() else failed_at end,
           error_class=$3,error_summary=$4,updated_at=now()
     where run_id=$1
  `,[runId,status,err?(err as Error).name:null,
     err?String((err as Error).message??err).slice(0,2000):null]);
}

async function main(){
  const doc=JSON.parse((await readFile(contractFile,'utf8')));
  const evidence=doc.interface_evidence;
  if(!evidence||typeof evidence!=='object'||Array.isArray(evidence)){
    throw new Error('contract.interface_evidence object required');
  }

  const required=['contract_version','discovery_type','transport','compile_modes',
    'field_map','required_fields','collection_methods','source_types','db_ingest_targets'];
  for(const k of required){
    if(!(k in doc)) throw new Error(`contract field missing: ${k}`);
  }

  const run=await createRun('RETAIL_R1B_SCRAPER_CONTRACT_REGISTER');
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','user',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[actor]);
    await c.query(`select set_config('app.process_run_id',$1,true)`,[run.runId]);
    await c.query(`select set_config('app.correlation_id',$1,true)`,[run.correlationId]);

    const x=await c.query(`
      select retail.r1b_register_scraper_contract(
        $1,$2,$3,$4::jsonb,$5::jsonb,$6,$7,$8,$9
      ) id
    `,[
      assetId,adapterId,doc.contract_version,JSON.stringify(doc),
      JSON.stringify(evidence),run.runId,run.correlationId,actor,
      supersedesArg||null
    ]);

    await c.query('commit');
    await finishRun(run.runId,'SUCCEEDED');
    console.log(JSON.stringify({
      event:'r1b_scraper_contract_registered',
      contractId:x.rows[0].id,
      processRunId:run.runId,
      correlationId:run.correlationId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishRun(run.runId,'FAILED',e);
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
