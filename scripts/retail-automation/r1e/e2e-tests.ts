import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL,max:8});
const [rulesetId]=process.argv.slice(2);

if(!rulesetId){
  throw new Error('usage: tsx e2e-tests.ts <ruleset_uuid>');
}

function reasonFamilyMatches(expected:string|null,reasons:any[]){
  if(!expected) return true;
  const family=expected.toUpperCase();
  return reasons.some(r=>{
    const x=String(r).toUpperCase();
    return x===family||x.startsWith(family+':')||x.startsWith(family+'_');
  });
}

async function main(){
  const ruleset=await pool.query(`
    select ruleset_code
    from retail.r1e_match_rulesets
    where id=$1 and certification_status='certified'
  `,[rulesetId]);
  if(!ruleset.rowCount) throw new Error('certified ruleset required');
  const code=ruleset.rows[0].ruleset_code;

  const fixtures=await pool.query(`
    select *
    from retail.r1e_e2e_qa_fixtures
    where active=true and ruleset_code=$1
    order by sequence_no,fixture_code
  `,[code]);

  if(!fixtures.rowCount){
    throw new Error('R1E V2.1 E2E fixtures are required');
  }

  const run=await startPersistentRun(
    pool,'RETAIL_R1E_V21_E2E_CERTIFY','system',
    'r1e-v21-e2e','R1E V2.1 E2E Certification',
    'retail.r1e_qualification_results','E2E_CERTIFICATION'
  );

  const results:any[]=[];
  let failed=0;

  try{
    for(const f of fixtures.rows){
      try{
        const r=await pool.query(`
          select retail.r1e_evaluate_capture_v21(
            $1,$2,$3,$4,$5,true
          ) result_id
        `,[
          f.raw_capture_id,rulesetId,
          run.runId,run.correlationId,
          'R1E V2.1 E2E Certification'
        ]);

        const q=(await pool.query(`
          select
            q.id,q.raw_capture_id,q.decision,q.reason_codes,
            q.evidence_sha256,q.evidence_json,
            q.r1d_attempt_evidence_sha256,q.r1d_attempt_evidence_json,
            q.observation_fingerprint,q.engine_version,
            q.r1d_certification_run_id,q.r1d_package_sha256,
            retail.r1e_result_is_current(q.id) result_current
          from retail.r1e_qualification_results q
          where q.id=$1
        `,[r.rows[0].result_id])).rows[0];

        const decisionOk=q.decision===f.expected_decision;
        const reasonOk=reasonFamilyMatches(
          f.expected_reason_family,
          Array.isArray(q.reason_codes)?q.reason_codes:[]
        );
        const evidenceOk=
          q.evidence_sha256===
          (await pool.query(
            `select retail.r1e_sha256_jsonb($1::jsonb) h`,
            [JSON.stringify(q.evidence_json)]
          )).rows[0].h;
        const attemptEvidenceOk=
          q.r1d_attempt_evidence_sha256===
          (await pool.query(
            `select retail.r1e_sha256_jsonb($1::jsonb) h`,
            [JSON.stringify(q.r1d_attempt_evidence_json)]
          )).rows[0].h;

        const ok=
          decisionOk&&reasonOk&&evidenceOk&&attemptEvidenceOk
          &&q.engine_version==='r1e-v2.1.0';

        if(!ok) failed++;

        results.push({
          fixtureCode:f.fixture_code,
          fixtureSha256:f.fixture_sha256,
          fixtureClass:f.fixture_class,
          expectedDecision:f.expected_decision,
          expectedReasonFamily:f.expected_reason_family,
          resultId:q.id,
          actualDecision:q.decision,
          reasonCodes:q.reason_codes,
          observationFingerprint:q.observation_fingerprint,
          engineVersion:q.engine_version,
          decisionOk,reasonOk,evidenceOk,attemptEvidenceOk,
          resultCurrent:q.result_current,
          ok
        });
      }catch(e){
        failed++;
        results.push({
          fixtureCode:f.fixture_code,
          fixtureSha256:f.fixture_sha256,
          fixtureClass:f.fixture_class,
          expectedDecision:f.expected_decision,
          expectedReasonFamily:f.expected_reason_family,
          ok:false,
          error:String((e as Error).message??e)
        });
      }
    }

    const pass=failed===0;
    await finishPersistentRun(
      pool,run.runId,pass?'SUCCEEDED':'FAILED',
      {
        seen:fixtures.rowCount,
        succeeded:fixtures.rowCount-failed,
        failed
      },
      pass?undefined:new Error(`${failed} E2E fixtures failed`),
      {results}
    );

    console.log(JSON.stringify({
      allPassed:pass,
      total:fixtures.rowCount,
      failed,
      results
    },null,2));

    if(!pass) process.exitCode=2;
  }catch(e){
    await finishPersistentRun(
      pool,run.runId,'FAILED',
      {seen:fixtures.rowCount,succeeded:0,failed:fixtures.rowCount},
      e
    ).catch(()=>undefined);
    throw e;
  }finally{
    await pool.end();
  }
}

main().catch(e=>{console.error(e);process.exitCode=1;});
