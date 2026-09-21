import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [rulesetId]=process.argv.slice(2);
const limit=Number(process.env.R1E_BATCH_LIMIT??'500');
const actor=process.env.R1E_ACTOR_NAME||'R1E V2.1 Batch Qualification Worker';

if(!rulesetId) throw new Error('usage: tsx qualify-batch.ts <ruleset_uuid>');
if(!Number.isInteger(limit)||limit<1||limit>10000){
  throw new Error('R1E_BATCH_LIMIT must be integer 1..10000');
}

async function main(){
  const binding=await pool.query(`
    select r1d_certification_run_id
    from retail.r1e_r1d_certification_binding
    where singleton=true
      and retail.r1e_r1d_binding_is_current()=true
  `);
  if(!binding.rowCount) throw new Error('Current R1D V2 binding required');
  const upstream=binding.rows[0].r1d_certification_run_id;

  const run=await startPersistentRun(
    pool,'RETAIL_R1E_QUALIFY_BATCH','worker',
    'r1e-v21-batch',actor,'retail.raw_product_captures'
  );

  const captures=await pool.query(`
    select p.raw_capture_id
    from retail.r1e_pending_captures p
    where not exists(
      select 1
      from retail.r1e_qualification_results q
      where q.raw_capture_id=p.raw_capture_id
        and q.ruleset_id=$1
        and q.r1d_certification_run_id=$2
        and q.engine_version='r1e-v2.1.0'
        and q.certification_fixture=false
    )
    order by p.captured_at,p.raw_capture_id
    limit $3
  `,[rulesetId,upstream,limit]);

  let succeeded=0,failed=0;
  const errors:any[]=[];

  for(const row of captures.rows){
    try{
      await pool.query(`
        select retail.r1e_evaluate_capture_v21(
          $1,$2,$3,$4,$5,false
        )
      `,[row.raw_capture_id,rulesetId,run.runId,run.correlationId,actor]);
      succeeded++;
    }catch(e){
      failed++;
      errors.push({
        rawCaptureId:row.raw_capture_id,
        error:String((e as Error).message??e).slice(0,1000)
      });
    }
  }

  await finishPersistentRun(
    pool,run.runId,
    failed===0?'SUCCEEDED':'FAILED',
    {seen:captures.rowCount,succeeded,failed},
    failed?new Error(`${failed} R1E V2.1 qualification failures`):undefined,
    {errors:errors.slice(0,100)}
  );

  console.log(JSON.stringify({
    event:'r1e_v21_batch_complete',
    seen:captures.rowCount,succeeded,failed,
    processRunId:run.runId,errors
  },null,2));

  await pool.end();
  if(failed) process.exitCode=2;
}

main().catch(e=>{console.error(e);process.exitCode=1;});
