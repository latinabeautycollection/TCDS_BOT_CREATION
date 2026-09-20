import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL,max:8});
const delay=(ms:number)=>new Promise(r=>setTimeout(r,ms));

async function main(){
  const scenario=(await pool.query(`
    select *
    from retail.r1f_e2e_qa_scenarios
    where active=true
      and scenario_type='CONCURRENCY'
    order by created_at,id
    limit 1
  `)).rows[0];

  if(!scenario){
    throw new Error('Fresh CONCURRENCY R1F V2 scenario required');
  }

  const prep=await startPersistentRun(
    pool,'RETAIL_R1F_V2_E2E_CERTIFY','system',
    'r1f-v2-concurrency-prep',
    'R1F V2 Recommendation Concurrency Prep',
    'retail.r1f','CONCURRENCY_PREP'
  );

  try{
    for(const jobId of scenario.job_ids){
      await pool.query(`
        select retail.r1f_ingest_completed_job_v2(
          $1,$2,$3,$4,true,$5
        )
      `,[
        jobId,prep.runId,prep.correlationId,
        'R1F V2 Recommendation Concurrency Prep',
        scenario.id
      ]);
    }

    await pool.query(`
      select retail.r1f_build_intelligence_v2(
        $1,$2,$3,$4,$5,true,$6
      )
    `,[
      scenario.intelligence_policy_id,
      scenario.window_end,
      prep.runId,
      prep.correlationId,
      'R1F V2 Recommendation Concurrency Prep',
      scenario.id
    ]);

    await finishPersistentRun(
      pool,prep.runId,'SUCCEEDED',
      {seen:scenario.job_ids.length,succeeded:scenario.job_ids.length,failed:0}
    );
  }catch(e){
    await finishPersistentRun(
      pool,prep.runId,'FAILED',
      {seen:scenario.job_ids.length,succeeded:0,failed:scenario.job_ids.length},
      e
    ).catch(()=>undefined);
    throw e;
  }

  const before=(await pool.query(`
    select count(*)::int c
    from retail.r1f_search_recommendations
    where certification_fixture=true
      and certification_batch_id=$1
      and engine_version='r1f-v2.0.0'
  `,[scenario.id])).rows[0].c;

  if(before!==0){
    throw new Error(
      'CONCURRENCY scenario must be fresh: recommendations already exist'
    );
  }

  const runA=await startPersistentRun(
    pool,'RETAIL_R1F_V2_RECOMMEND_CONCURRENCY','system',
    'r1f-v2-rec-race-a','R1F V2 Recommendation Race A',
    'retail.r1f_search_recommendations','CONCURRENCY_TEST'
  );
  const runB=await startPersistentRun(
    pool,'RETAIL_R1F_V2_RECOMMEND_CONCURRENCY','system',
    'r1f-v2-rec-race-b','R1F V2 Recommendation Race B',
    'retail.r1f_search_recommendations','CONCURRENCY_TEST'
  );

  const a=await pool.connect();
  const b=await pool.connect();
  const gates:any[]=[];

  try{
    await a.query('begin');
    await b.query('begin');

    const qa=await a.query(`
      select retail.r1f_generate_recommendations_v2(
        $1,$2,$3,$4,$5,true,$6
      ) created
    `,[
      scenario.intelligence_policy_id,
      scenario.window_end,
      runA.runId,runA.correlationId,
      'R1F V2 Recommendation Race A',
      scenario.id
    ]);

    const bPromise=b.query(`
      select retail.r1f_generate_recommendations_v2(
        $1,$2,$3,$4,$5,true,$6
      ) created
    `,[
      scenario.intelligence_policy_id,
      scenario.window_end,
      runB.runId,runB.correlationId,
      'R1F V2 Recommendation Race B',
      scenario.id
    ]);

    await delay(250);
    await a.query('commit');
    const qb=await bPromise;
    await b.query('commit');

    const rows=await pool.query(`
      select recommendation_key,count(*)::int c
      from retail.r1f_search_recommendations
      where certification_fixture=true
        and certification_batch_id=$1
        and engine_version='r1f-v2.0.0'
      group by recommendation_key
      order by recommendation_key
    `,[scenario.id]);

    const total=rows.rows.reduce((n,x)=>n+x.c,0);
    const duplicates=rows.rows.filter(x=>x.c!==1);

    gates.push({
      name:'first_generator_inserts_recommendations',
      ok:Number(qa.rows[0].created)>0,
      detail:qa.rows[0]
    });
    gates.push({
      name:'second_generator_idempotent_after_serialization',
      ok:Number(qb.rows[0].created)===0,
      detail:qb.rows[0]
    });
    gates.push({
      name:'recommendation_keys_unique',
      ok:duplicates.length===0,
      detail:{total,duplicateKeys:duplicates}
    });
    gates.push({
      name:'recommendations_created',
      ok:total>0,
      detail:{total}
    });

    const pass=gates.every(x=>x.ok);

    await finishPersistentRun(
      pool,runA.runId,pass?'SUCCEEDED':'FAILED',
      {seen:1,succeeded:pass?1:0,failed:pass?0:1},
      pass?undefined:new Error('R1F V2 recommendation concurrency failed'),
      {scenarioCode:scenario.scenario_code,gates}
    );
    await finishPersistentRun(
      pool,runB.runId,pass?'SUCCEEDED':'FAILED',
      {seen:1,succeeded:pass?1:0,failed:pass?0:1},
      pass?undefined:new Error('R1F V2 recommendation concurrency failed'),
      {scenarioCode:scenario.scenario_code,gates}
    );

    console.log(JSON.stringify({
      allPassed:pass,
      scenarioCode:scenario.scenario_code,
      scenarioId:scenario.id,
      fixtureSha256:scenario.fixture_sha256,
      gates
    },null,2));

    if(!pass) process.exitCode=2;
  }catch(e){
    try{await a.query('rollback');}catch{}
    try{await b.query('rollback');}catch{}
    await finishPersistentRun(
      pool,runA.runId,'FAILED',{seen:1,succeeded:0,failed:1},e
    ).catch(()=>undefined);
    await finishPersistentRun(
      pool,runB.runId,'FAILED',{seen:1,succeeded:0,failed:1},e
    ).catch(()=>undefined);
    throw e;
  }finally{
    a.release();
    b.release();
    await pool.end();
  }
}

main().catch(e=>{console.error(e);process.exitCode=1;});
