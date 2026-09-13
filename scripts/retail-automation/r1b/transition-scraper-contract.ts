import { Pool } from 'pg';
import { randomUUID } from 'node:crypto';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [contractId,newStatus,actorArg,reasonArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1B_APPROVER||'R1B Scraper Contract Authority';
if(!contractId||!newStatus){
  throw new Error('usage: tsx transition-scraper-contract.ts <contract_uuid> <contract_verified|qa_passed|certified_for_r1|blocked|retired> [actor] [reason]');
}
const processByStatus:Record<string,string>={
  contract_verified:'RETAIL_R1B_SCRAPER_CONTRACT_VERIFY',
  qa_passed:'RETAIL_R1B_SCRAPER_CONTRACT_QA',
  certified_for_r1:'RETAIL_R1B_SCRAPER_CONTRACT_CERTIFY',
  blocked:'RETAIL_R1B_SCRAPER_CONTRACT_BLOCK',
  retired:'RETAIL_R1B_SCRAPER_CONTRACT_RETIRE'
};

async function main(){
  const processName=processByStatus[newStatus];
  if(!processName) throw new Error(`unsupported lifecycle status ${newStatus}`);
  const correlationId=randomUUID();

  const run=await pool.query(`
    insert into arb.process_runs(
      process_name,process_stage,status,correlation_id,
      actor_type,actor_id,actor_name,
      worker_name,worker_instance_id,code_version,ruleset_version,
      entity_type,idempotency_key
    ) values(
      $1,'EXECUTE','STARTED',$2,'user',$3,$3,
      'r1b-scraper-contract-lifecycle',$4,$5,'r1b-v4.0.0',
      'retail.retail_scraper_contracts',$6
    ) returning run_id
  `,[processName,correlationId,actor,
     process.env.WORKER_INSTANCE_ID??'r1b-v4-1',
     process.env.CODE_VERSION??process.env.GIT_SHA??'unknown',
     `${processName}:${contractId}:${correlationId}`]);

  const runId=run.rows[0].run_id;
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`
      select retail.r1b_transition_scraper_contract(
        $1,$2,$3,$4,$5,$6
      )
    `,[contractId,newStatus,runId,correlationId,actor,reasonArg||null]);
    await c.query('commit');

    await pool.query(`
      update arb.process_runs
         set status='SUCCEEDED',completed_at=now(),updated_at=now()
       where run_id=$1
    `,[runId]);

    console.log(JSON.stringify({
      event:'r1b_scraper_contract_transition',
      contractId,newStatus,processRunId:runId,correlationId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await pool.query(`
      update arb.process_runs
         set status='FAILED',failed_at=now(),
             error_class=$2,error_summary=$3,updated_at=now()
       where run_id=$1
    `,[runId,(e as Error).name,String((e as Error).message??e).slice(0,2000)]);
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
