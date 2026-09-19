import { Pool } from 'pg';
import { randomUUID } from 'node:crypto';

const pool=new Pool({connectionString:process.env.DATABASE_URL,max:20});
const workers=Number(process.env.R1D_CONCURRENCY_WORKERS??'8');

if(process.env.R1D_RUN_CONCURRENCY_TESTS!=='true'){
  console.log(JSON.stringify({
    allPassed:false,skipped:true,
    reason:'Set R1D_RUN_CONCURRENCY_TESTS=true'
  },null,2));
  process.exitCode=2;
}else{
  main().catch(e=>{console.error(e);process.exitCode=1;});
}

async function main(){
  const fixtures=await pool.query(`
    select count(*)::int n
    from retail.r1d_dispatch_jobs
    where certification_fixture=true
      and status in('queued','retry_wait')
  `);
  if(Number(fixtures.rows[0].n)<2){
    throw new Error('Prepare at least two certification fixtures first');
  }

  const correlationId=randomUUID();
  const run=await pool.query(`
    insert into arb.process_runs(
      process_name,process_stage,status,correlation_id,
      actor_type,actor_id,actor_name,worker_name,worker_instance_id,
      code_version,ruleset_version,entity_type,idempotency_key
    ) values(
      'RETAIL_R1D_CERTIFY','CONCURRENCY_TEST','STARTED',$1,
      'system','r1d-concurrency-test','R1D Concurrency Test',
      'r1d-concurrency-test',$2,$3,'r1d-v2.0.0',
      'retail.r1d_dispatch_jobs',$4
    ) returning run_id
  `,[
    correlationId,process.env.WORKER_INSTANCE_ID??'r1d-concurrency-v2',
    process.env.CODE_VERSION??'unknown',`R1D_V2_CONCURRENCY:${correlationId}`
  ]);
  const runId=run.rows[0].run_id;

  const claims=await Promise.all(
    Array.from({length:workers},async(_,i)=>{
      const worker=`qa-concurrency-${i}-${randomUUID()}`;
      const r=await pool.query(`
        select * from retail.r1d_claim_next_job_v2($1,$2,$3,true)
      `,[worker,runId,correlationId]);
      return r.rows[0]??null;
    })
  );

  const claimed=claims.filter(Boolean) as any[];
  const ids=claimed.map(x=>x.job_id);
  const gates:any[]=[
    {
      name:'qa_only_claims',
      ok:claimed.length>=2,
      detail:{workers,claimed:claimed.length}
    },
    {
      name:'no_duplicate_job_lease',
      ok:new Set(ids).size===ids.length,
      detail:{ids}
    }
  ];

  if(ids.length){
    const prod=await pool.query(`
      select count(*)::int n
      from retail.r1d_dispatch_jobs
      where id=any($1::uuid[]) and certification_fixture=false
    `,[ids]);
    gates.push({
      name:'no_production_job_claimed',
      ok:Number(prod.rows[0].n)===0,detail:prod.rows[0]
    });

    const binding=await pool.query(`
      select j.dispatch_binding_id,b.max_concurrency,count(*)::int n
      from retail.r1d_dispatch_jobs j
      join retail.r1d_dispatch_bindings b on b.id=j.dispatch_binding_id
      where j.id=any($1::uuid[])
      group by j.dispatch_binding_id,b.max_concurrency
    `,[ids]);
    gates.push({
      name:'binding_concurrency_not_exceeded',
      ok:binding.rows.every(x=>Number(x.n)<=Number(x.max_concurrency)),
      detail:binding.rows
    });

    const platform=await pool.query(`
      select j.platform_id,min(p.max_parallel)::int max_parallel,count(*)::int n
      from retail.r1d_dispatch_jobs j
      join retail.r1d_schedule_policies p on p.id=j.schedule_policy_id
      where j.id=any($1::uuid[])
      group by j.platform_id
    `,[ids]);
    gates.push({
      name:'platform_concurrency_not_exceeded',
      ok:platform.rows.every(x=>Number(x.n)<=Number(x.max_parallel)),
      detail:platform.rows
    });

    for(const x of claimed){
      await pool.query(`
        select retail.r1d_fail_pre_dispatch(
          $1,$2,'QA_CONCURRENCY_CLEANUP',
          'Certification fixture released before dispatch',
          false,$3,$4
        )
      `,[x.job_id,x.lease_token,runId,correlationId]);
    }

    await pool.query(`
      update retail.r1d_dispatch_jobs
      set status='cancelled',updated_at=now()
      where id=any($1::uuid[])
        and certification_fixture=true
        and status='retry_wait'
    `,[ids]);

    const reserved=await pool.query(`
      select count(*)::int n
      from retail.r1d_budget_reservations
      where job_id=any($1::uuid[]) and status='reserved'
    `,[ids]);
    gates.push({
      name:'qa_cleanup_releases_budget',
      ok:Number(reserved.rows[0].n)===0,detail:reserved.rows[0]
    });

    const rates=await pool.query(`
      select count(*)::int n
      from retail.r1d_rate_reservations
      where job_id=any($1::uuid[]) and status='reserved'
    `,[ids]);
    gates.push({
      name:'qa_cleanup_releases_rate_slots',
      ok:Number(rates.rows[0].n)===0,detail:rates.rows[0]
    });

    const leases=await pool.query(`
      select count(*)::int n
      from retail.r1d_dispatch_jobs
      where id=any($1::uuid[])
        and status in('leased','dispatching')
    `,[ids]);
    gates.push({
      name:'qa_cleanup_releases_leases',
      ok:Number(leases.rows[0].n)===0,detail:leases.rows[0]
    });
  }

  const pass=gates.every(x=>x.ok);
  await pool.query(`
    update arb.process_runs
    set status=$2,certification_status=$3,
        certification_report_json=$4::jsonb,
        completed_at=case when $2='SUCCEEDED' then now() else completed_at end,
        failed_at=case when $2='FAILED' then now() else failed_at end,
        updated_at=now()
    where run_id=$1
  `,[runId,pass?'SUCCEEDED':'FAILED',pass?'CERTIFIED':'FAILED',
     JSON.stringify({gates,workers,claimed:claimed.length})]);

  console.log(JSON.stringify({
    allPassed:pass,workers,claimed:claimed.length,gates
  },null,2));
  await pool.end();
  if(!pass) process.exitCode=2;
}
