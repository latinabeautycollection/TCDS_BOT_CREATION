import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [policyId,windowEndArg]=process.argv.slice(2);
const actor=process.env.R1F_ACTOR_NAME||'R1F V2 Recommendation Worker';

if(!policyId){
  throw new Error('usage: tsx generate-recommendations.ts <policy_uuid> [window_end_iso]');
}

async function main(){
  const windowEnd=windowEndArg||new Date().toISOString();
  const run=await startPersistentRun(
    pool,'RETAIL_R1F_RECOMMEND','worker',
    'r1f-recommend-worker',actor,
    'retail.r1f_search_recommendations'
  );
  try{
    const r=await pool.query(`
      select retail.r1f_generate_recommendations_v2(
        $1,$2::timestamptz,$3,$4,$5,false,NULL
      ) created
    `,[policyId,windowEnd,run.runId,run.correlationId,actor]);

    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:Number(r.rows[0].created),succeeded:Number(r.rows[0].created),failed:0},
      undefined,{policyId,windowEnd}
    );

    console.log(JSON.stringify({
      event:'r1f_v2_recommendations_generated',
      policyId,windowEnd,
      created:Number(r.rows[0].created),
      processRunId:run.runId
    },null,2));
  }catch(e){
    await finishPersistentRun(pool,run.runId,'FAILED',{},e);
    throw e;
  }finally{
    await pool.end();
  }
}

main().catch(e=>{console.error(e);process.exitCode=1;});
