import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL,max:8});
const [rulesetId]=process.argv.slice(2);

if(!rulesetId){
  throw new Error('usage: tsx duplicate-concurrency-tests.ts <ruleset_uuid>');
}

const delay=(ms:number)=>new Promise(r=>setTimeout(r,ms));

async function main(){
  const ruleset=await pool.query(`
    select ruleset_code
    from retail.r1e_match_rulesets
    where id=$1 and certification_status='certified'
  `,[rulesetId]);
  if(!ruleset.rowCount) throw new Error('certified ruleset required');
  const code=ruleset.rows[0].ruleset_code;

  const binding=await pool.query(`
    select r1d_certification_run_id
    from retail.r1e_r1d_certification_binding
    where singleton=true and retail.r1e_r1d_binding_is_current()=true
  `);
  if(!binding.rowCount) throw new Error('current R1D binding required');
  const upstream=binding.rows[0].r1d_certification_run_id;

  // Certification retries reuse an immutable successful race proof instead of
  // requiring another billable scraper execution.
  const provenFixture=await pool.query(`
    select f.*
    from retail.r1e_duplicate_race_fixtures f
    where f.active=true
      and f.ruleset_code=$1
      and (
        select count(*)
        from retail.r1e_qualification_results q
        where q.raw_capture_id in(f.capture_a_id,f.capture_b_id)
          and q.ruleset_id=$2
          and q.r1d_certification_run_id=$3
          and q.engine_version='r1e-v2.1.0'
      )=2
      and exists(
        select 1
        from retail.r1e_qualification_results qualified
        join retail.r1e_qualification_results duplicate
          on duplicate.duplicate_of_result_id=qualified.id
         and duplicate.observation_fingerprint=
             qualified.observation_fingerprint
        where qualified.raw_capture_id in(f.capture_a_id,f.capture_b_id)
          and duplicate.raw_capture_id in(f.capture_a_id,f.capture_b_id)
          and qualified.ruleset_id=$2
          and duplicate.ruleset_id=$2
          and qualified.r1d_certification_run_id=$3
          and duplicate.r1d_certification_run_id=$3
          and qualified.engine_version='r1e-v2.1.0'
          and duplicate.engine_version='r1e-v2.1.0'
          and qualified.decision='QUALIFIED'
          and duplicate.decision='REJECTED_DUPLICATE'
          and duplicate.reason_codes ? 'DUPLICATE_OBSERVATION'
      )
    order by f.created_at,f.id
    limit 1
  `,[code,rulesetId,upstream]);

  if(provenFixture.rowCount){
    const f=provenFixture.rows[0];
    const proof=await pool.query(`
      select id,raw_capture_id,decision,reason_codes,
             observation_fingerprint,duplicate_of_result_id,
             evidence_sha256,engine_version
      from retail.r1e_qualification_results
      where raw_capture_id in($1,$2)
        and ruleset_id=$3
        and r1d_certification_run_id=$4
        and engine_version='r1e-v2.1.0'
      order by qualified_at,id
    `,[f.capture_a_id,f.capture_b_id,rulesetId,upstream]);

    const rows=proof.rows;
    const qualified=rows.filter(x=>x.decision==='QUALIFIED');
    const duplicates=rows.filter(x=>x.decision==='REJECTED_DUPLICATE');
    const gates=[
      {name:'persisted_concurrency_proof_reused',ok:true},
      {
        name:'two_full_evaluator_results_created',
        ok:rows.length===2,
        detail:rows
      },
      {
        name:'same_observation_fingerprint',
        ok:rows.length===2
          && rows[0].observation_fingerprint===
             rows[1].observation_fingerprint,
        detail:rows.map(x=>x.observation_fingerprint)
      },
      {
        name:'exactly_one_qualified',
        ok:qualified.length===1
      },
      {
        name:'exactly_one_rejected_duplicate',
        ok:duplicates.length===1
      },
      {
        name:'duplicate_reason_correct',
        ok:duplicates.length===1
          && duplicates[0].reason_codes.includes(
            'DUPLICATE_OBSERVATION'
          )
      },
      {
        name:'duplicate_points_to_qualified',
        ok:duplicates.length===1
          && qualified.length===1
          && duplicates[0].duplicate_of_result_id===qualified[0].id
      },
      {
        name:'both_v21_engine',
        ok:rows.every(x=>x.engine_version==='r1e-v2.1.0')
      }
    ];
    const pass=gates.every(x=>x.ok);

    console.log(JSON.stringify({
      allPassed:pass,
      reusedPersistedProof:true,
      fixtureCode:f.fixture_code,
      fixtureSha256:f.fixture_sha256,
      results:rows,
      gates
    },null,2));

    await pool.end();
    if(!pass) process.exitCode=2;
    return;
  }

  // Require a fresh pair so the real production persistence path is exercised.
  const fixture=await pool.query(`
    select f.*
    from retail.r1e_duplicate_race_fixtures f
    where f.active=true
      and f.ruleset_code=$1
      and not exists(
        select 1
        from retail.r1e_qualification_results q
        where q.raw_capture_id in(f.capture_a_id,f.capture_b_id)
          and q.ruleset_id=$2
          and q.r1d_certification_run_id=$3
          and q.engine_version='r1e-v2.1.0'
      )
    order by f.created_at,f.id
    limit 1
  `,[code,rulesetId,upstream]);

  if(!fixture.rowCount){
    throw new Error(
      'Fresh active duplicate-race fixture pair required for R1E V2.1 freeze certification'
    );
  }
  const f=fixture.rows[0];

  const runA=await startPersistentRun(
    pool,'RETAIL_R1E_V21_DUPLICATE_RACE','system',
    'r1e-v21-race-a','R1E V2.1 Duplicate Race A',
    'retail.r1e_qualification_results','CONCURRENCY_TEST'
  );
  const runB=await startPersistentRun(
    pool,'RETAIL_R1E_V21_DUPLICATE_RACE','system',
    'r1e-v21-race-b','R1E V2.1 Duplicate Race B',
    'retail.r1e_qualification_results','CONCURRENCY_TEST'
  );

  const a=await pool.connect();
  const b=await pool.connect();
  const gates:any[]=[];

  try{
    await a.query('begin');
    await b.query('begin');

    // A executes fully but its row/advisory lock remains uncommitted.
    const qa=await a.query(`
      select retail.r1e_evaluate_capture_v21(
        $1,$2,$3,$4,$5,true
      ) result_id
    `,[
      f.capture_a_id,rulesetId,
      runA.runId,runA.correlationId,
      'R1E V2.1 Duplicate Race A'
    ]);

    // B starts while A still owns the transaction-level observation lock.
    const bPromise=b.query(`
      select retail.r1e_evaluate_capture_v21(
        $1,$2,$3,$4,$5,true
      ) result_id
    `,[
      f.capture_b_id,rulesetId,
      runB.runId,runB.correlationId,
      'R1E V2.1 Duplicate Race B'
    ]);

    await delay(250);
    await a.query('commit');

    const qb=await bPromise;
    await b.query('commit');

    const ids=[qa.rows[0].result_id,qb.rows[0].result_id];
    const results=await pool.query(`
      select id,raw_capture_id,decision,reason_codes,
             observation_fingerprint,duplicate_of_result_id,
             evidence_sha256,engine_version
      from retail.r1e_qualification_results
      where id=any($1::uuid[])
      order by qualified_at,id
    `,[ids]);

    const rows=results.rows;
    const qualified=rows.filter(x=>x.decision==='QUALIFIED');
    const duplicates=rows.filter(x=>x.decision==='REJECTED_DUPLICATE');

    gates.push({
      name:'two_full_evaluator_results_created',
      ok:rows.length===2,
      detail:rows
    });
    gates.push({
      name:'same_observation_fingerprint',
      ok:rows.length===2
        && rows[0].observation_fingerprint===rows[1].observation_fingerprint,
      detail:rows.map(x=>x.observation_fingerprint)
    });
    gates.push({
      name:'exactly_one_qualified',
      ok:qualified.length===1,
      detail:{qualified:qualified.length}
    });
    gates.push({
      name:'exactly_one_rejected_duplicate',
      ok:duplicates.length===1,
      detail:{duplicates:duplicates.length}
    });
    gates.push({
      name:'duplicate_reason_correct',
      ok:duplicates.length===1
        && duplicates[0].reason_codes.includes('DUPLICATE_OBSERVATION'),
      detail:duplicates[0]?.reason_codes
    });
    gates.push({
      name:'duplicate_points_to_qualified',
      ok:duplicates.length===1
        && qualified.length===1
        && duplicates[0].duplicate_of_result_id===qualified[0].id,
      detail:{
        duplicateOf:duplicates[0]?.duplicate_of_result_id,
        qualifiedId:qualified[0]?.id
      }
    });
    gates.push({
      name:'both_v21_engine',
      ok:rows.every(x=>x.engine_version==='r1e-v2.1.0')
    });

    const pass=gates.every(x=>x.ok);

    await finishPersistentRun(
      pool,runA.runId,pass?'SUCCEEDED':'FAILED',
      {seen:1,succeeded:pass?1:0,failed:pass?0:1},
      pass?undefined:new Error('R1E V2.1 duplicate race gates failed'),
      {fixtureCode:f.fixture_code,fixtureSha256:f.fixture_sha256,gates}
    );
    await finishPersistentRun(
      pool,runB.runId,pass?'SUCCEEDED':'FAILED',
      {seen:1,succeeded:pass?1:0,failed:pass?0:1},
      pass?undefined:new Error('R1E V2.1 duplicate race gates failed'),
      {fixtureCode:f.fixture_code,fixtureSha256:f.fixture_sha256,gates}
    );

    console.log(JSON.stringify({
      allPassed:pass,
      fixtureCode:f.fixture_code,
      fixtureSha256:f.fixture_sha256,
      results:rows,
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
    a.release();b.release();await pool.end();
  }
}

main().catch(e=>{console.error(e);process.exitCode=1;});
