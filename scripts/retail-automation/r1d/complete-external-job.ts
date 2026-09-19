import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [outboxMessageId,leaseToken,resultFile]=process.argv.slice(2);
const actor=process.env.R1D_WORKER_ID||'r1d-external-completer';

if(!outboxMessageId||!leaseToken||!resultFile){
  throw new Error(
    'usage: tsx complete-external-job.ts <outbox_message_uuid> <lease_token> <result.json>'
  );
}

async function main(){
  const result=JSON.parse(await readFile(resultFile,'utf8'));
  const run=await startPersistentRun(
    pool,'RETAIL_R1D_DISPATCH','worker',
    actor,actor,'retail.r1d_dispatch_outbox'
  );

  try{
    await pool.query(`
      select retail.r1d_finish_external_job(
        $1,$2,$3,$4,$5,$6,$7::jsonb,$8,$9,$10
      )
    `,[
      outboxMessageId,leaseToken,!!result.success,
      result.actual_cost_usd??null,
      result.error_code??null,result.error_message??null,
      JSON.stringify(result.metrics??{}),
      result.exit_code??null,
      run.runId,run.correlationId
    ]);

    await finishPersistentRun(
      pool,run.runId,
      result.success?'SUCCEEDED':'FAILED',
      {seen:1,succeeded:result.success?1:0,failed:result.success?0:1},
      result.success?undefined:new Error(result.error_message??'external dispatch failed')
    );

    console.log(JSON.stringify({
      event:'r1d_external_attempt_completed',
      outboxMessageId,success:!!result.success,
      processRunId:run.runId
    },null,2));
  }catch(e){
    await finishPersistentRun(
      pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e
    );
    throw e;
  }finally{
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
