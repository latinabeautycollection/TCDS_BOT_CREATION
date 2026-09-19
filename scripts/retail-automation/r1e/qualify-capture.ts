import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [captureId,rulesetId]=process.argv.slice(2);
const actor=process.env.R1E_ACTOR_NAME||'R1E V2.1 Qualification Worker';

if(!captureId||!rulesetId){
  throw new Error('usage: tsx qualify-capture.ts <raw_capture_uuid> <ruleset_uuid>');
}

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1E_QUALIFY_CAPTURE','worker',
    'r1e-v21-worker',actor,'retail.raw_product_captures'
  );

  try{
    const r=await pool.query(`
      select retail.r1e_evaluate_capture_v21(
        $1,$2,$3,$4,$5,false
      ) result_id
    `,[captureId,rulesetId,run.runId,run.correlationId,actor]);

    const q=await pool.query(`
      select id,decision,identity_score,accessory_score,
             condition_score,confidence_score,reason_codes,
             observation_fingerprint,product_identity_fingerprint,
             r1d_certification_run_id,r1a_revision_id,r1a_revision_hash,
             engine_version
      from retail.r1e_qualification_results
      where id=$1
    `,[r.rows[0].result_id]);

    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0}
    );

    console.log(JSON.stringify({
      event:'r1e_v21_capture_qualified',
      result:q.rows[0],
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
