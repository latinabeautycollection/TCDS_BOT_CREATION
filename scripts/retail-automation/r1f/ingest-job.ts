import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [jobId]=process.argv.slice(2);
const actor=process.env.R1F_ACTOR_NAME||'R1F V2 Fact Ingestion Worker';

if(!jobId){
  throw new Error('usage: tsx ingest-job.ts <r1d_job_uuid>');
}

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1F_INGEST_JOB','worker',
    'r1f-ingest-worker',actor,'retail.r1d_dispatch_jobs'
  );
  try{
    const r=await pool.query(`
      select retail.r1f_ingest_completed_job_v2(
        $1,$2,$3,$4,false,NULL
      ) fact_id
    `,[jobId,run.runId,run.correlationId,actor]);

    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:1,succeeded:1,failed:0},
      undefined,{factId:r.rows[0].fact_id}
    );

    console.log(JSON.stringify({
      event:'r1f_v2_job_ingested',
      jobId,
      factId:r.rows[0].fact_id,
      processRunId:run.runId
    },null,2));
  }catch(e){
    await finishPersistentRun(
      pool,run.runId,'FAILED',
      {seen:1,succeeded:0,failed:1},e
    );
    throw e;
  }finally{
    await pool.end();
  }
}

main().catch(e=>{console.error(e);process.exitCode=1;});
