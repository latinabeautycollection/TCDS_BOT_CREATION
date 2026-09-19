import { Pool } from 'pg';
import { createHash,randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFile,writeFile } from 'node:fs/promises';
import path from 'node:path';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [rulesetId]=process.argv.slice(2);
const actor=process.env.R1E_CERTIFIER||'R1E V2.1 Certification Authority';
const packageFile=process.env.R1E_PACKAGE_ZIP;
const outFile=process.env.R1E_CERT_EVIDENCE_OUT||
  'r1e-v2.1-certification-evidence.json';

if(!rulesetId||!packageFile){
  throw new Error(
    'usage: R1E_PACKAGE_ZIP=<exact-release.zip> tsx certify.ts <ruleset_uuid>'
  );
}

const sha=(b:Buffer|string)=>createHash('sha256').update(b).digest('hex');

function canonicalize(v:any):any{
  if(Array.isArray(v)) return v.map(canonicalize);
  if(v&&typeof v==='object'){
    return Object.keys(v).sort().reduce((o:any,k)=>{
      o[k]=canonicalize(v[k]); return o;
    },{});
  }
  return v;
}
const canonicalStringify=(v:any)=>JSON.stringify(canonicalize(v));

function runJson(script:string,args:string[]=[]){
  try{
    const raw=execFileSync(
      process.execPath,
      ['--import','tsx',script,...args],
      {
        cwd:process.env.REPO_ROOT??process.cwd(),
        encoding:'utf8',
        env:process.env
      }
    );
    return JSON.parse(raw);
  }catch(e:any){
    return {
      allPassed:false,
      error:String(e?.stderr||e?.message||e),
      gates:[],
      results:[]
    };
  }
}

function reasonFamilyMatches(expected:string|null,reasons:any[]){
  if(!expected) return true;
  const family=expected.toUpperCase();
  return reasons.some(r=>{
    const x=String(r).toUpperCase();
    return x===family
      ||x.startsWith(family+':')
      ||x.startsWith(family+'_');
  });
}

const pct=(a:number,b:number)=>b?100*a/b:0;

async function main(){
  const releaseBytes=await readFile(path.resolve(packageFile!));
  const releaseSha=sha(releaseBytes);

  const c=await pool.connect();
  const correlationId=randomUUID();
  let runId:string|undefined;

  try{
    const run=await c.query(`
      insert into arb.process_runs(
        process_name,process_stage,status,correlation_id,
        actor_type,actor_id,actor_name,
        worker_name,worker_instance_id,code_version,ruleset_version,
        entity_type,idempotency_key
      ) values(
        'RETAIL_R1E_CERTIFY','FREEZE_GATE','STARTED',$1,
        'system','r1e-v21-certifier',$2,
        'r1e-v21-certify',$3,$4,'r1e-v2.1.0',
        'retail.r1e',$5
      ) returning run_id
    `,[
      correlationId,actor,
      process.env.WORKER_INSTANCE_ID??'r1e-v21-cert-1',
      process.env.CODE_VERSION??'unknown',
      `R1E_V21_CERT:${correlationId}`
    ]);
    runId=run.rows[0].run_id;

    const binding=(await c.query(`
      select b.*,cr.certification_status,cr.certification_version
      from retail.r1e_r1d_certification_binding b
      join retail.r1d_certification_runs cr
        on cr.id=b.r1d_certification_run_id
      where b.singleton=true
    `)).rows[0];

    if(!binding||
       (await c.query(
         `select retail.r1e_r1d_binding_is_current() ok`
       )).rows[0].ok!==true){
      throw new Error('Exact current R1D V2 binding missing/stale');
    }

    const ruleset=(await c.query(`
      select *
      from retail.r1e_match_rulesets
      where id=$1 and certification_status='certified'
    `,[rulesetId])).rows[0];

    if(!ruleset){
      throw new Error('Certified R1E ruleset required');
    }

    await c.query(
      `select retail.r1e_validate_ruleset_v2($1::jsonb)`,
      [JSON.stringify(ruleset.rules_json)]
    );

    const policy=(await c.query(`
      select *
      from retail.r1e_certification_policies
      where certification_status='certified'
      order by certified_at desc,id::text desc
      limit 1
    `)).rows[0];

    if(!policy){
      throw new Error('Certified immutable R1E V2.1 certification policy required');
    }

    await c.query(
      `select retail.r1e_validate_cert_policy($1::jsonb)`,
      [JSON.stringify(policy.policy_json)]
    );

    const policyHash=(await c.query(
      `select retail.r1e_sha256_jsonb($1::jsonb) h`,
      [JSON.stringify(policy.policy_json)]
    )).rows[0].h;

    if(policy.policy_sha256!==policyHash){
      throw new Error('Certification policy SHA mismatch');
    }

    const fixtures=(await c.query(`
      select
        f.fixture_code,f.fixture_class,
        f.expected_decision,f.expected_reason_family,
        f.fixture_sha256,
        retail.r1e_match_documents_v21(
          f.target_identity_json,
          f.returned_identity_json,
          rs.rules_json,
          f.fixture_class='duplicate'
        ) result,
        retail.r1e_sha256_jsonb(
          retail.r1e_match_documents_v21(
            f.target_identity_json,
            f.returned_identity_json,
            rs.rules_json,
            f.fixture_class='duplicate'
          )
        ) result_sha
      from retail.r1e_qa_fixtures f
      join retail.r1e_match_rulesets rs
        on rs.ruleset_code=f.ruleset_code
       and rs.id=$1
      where f.active=true
      order by f.fixture_code
    `,[rulesetId])).rows;

    const secondReplay=(await c.query(`
      select
        f.fixture_code,
        retail.r1e_sha256_jsonb(
          retail.r1e_match_documents_v21(
            f.target_identity_json,
            f.returned_identity_json,
            rs.rules_json,
            f.fixture_class='duplicate'
          )
        ) result_sha
      from retail.r1e_qa_fixtures f
      join retail.r1e_match_rulesets rs
        on rs.ruleset_code=f.ruleset_code
       and rs.id=$1
      where f.active=true
      order by f.fixture_code
    `,[rulesetId])).rows;

    const replayMap=new Map(
      secondReplay.map((x:any)=>[x.fixture_code,x.result_sha])
    );
    const replaySame=fixtures.every(
      (x:any)=>replayMap.get(x.fixture_code)===x.result_sha
    );

    const p=policy.policy_json;
    const classCounts:Record<string,number>={};
    for(const f of fixtures){
      classCounts[f.fixture_class]=(classCounts[f.fixture_class]??0)+1;
    }

    const expectedPositive=fixtures.filter(
      (f:any)=>f.expected_decision==='QUALIFIED'
    );
    const actualPositive=fixtures.filter(
      (f:any)=>f.result?.decision==='QUALIFIED'
    );
    const truePositive=fixtures.filter(
      (f:any)=>
        f.expected_decision==='QUALIFIED'
        &&f.result?.decision==='QUALIFIED'
    );
    const expectedNegative=fixtures.filter(
      (f:any)=>f.expected_decision!=='QUALIFIED'
    );
    const falsePositive=expectedNegative.filter(
      (f:any)=>f.result?.decision==='QUALIFIED'
    );
    const correct=fixtures.filter(
      (f:any)=>f.result?.decision===f.expected_decision
    );
    const duplicateRows=fixtures.filter(
      (f:any)=>f.fixture_class==='duplicate'
    );
    const duplicateCorrect=duplicateRows.filter(
      (f:any)=>f.result?.decision==='REJECTED_DUPLICATE'
    );
    const variantRows=fixtures.filter(
      (f:any)=>f.fixture_class==='wrong_variant'
    );
    const variantFalsePositive=variantRows.filter(
      (f:any)=>f.result?.decision==='QUALIFIED'
    );
    const reasonEligible=fixtures.filter(
      (f:any)=>f.expected_decision!=='QUALIFIED'
    );
    const reasonCorrect=reasonEligible.filter(
      (f:any)=>
        !!f.expected_reason_family
        &&reasonFamilyMatches(
          f.expected_reason_family,
          Array.isArray(f.result?.reason_codes)
            ? f.result.reason_codes : []
        )
    );
    const evidenceComplete=fixtures.filter(
      (f:any)=>
        f.result
        &&typeof f.result.decision==='string'
        &&Array.isArray(f.result.reason_codes)
        &&f.result.scores
        &&f.result.variant_match
        &&f.result.identifier_match
    );

    const metrics={
      totalFixtures:fixtures.length,
      classCounts,
      decisionAccuracy:pct(correct.length,fixtures.length),
      positivePrecision:pct(truePositive.length,actualPositive.length),
      positiveRecall:pct(truePositive.length,expectedPositive.length),
      falsePositiveRate:pct(falsePositive.length,expectedNegative.length),
      wrongVariantFalsePositiveRate:
        pct(variantFalsePositive.length,variantRows.length),
      duplicateAccuracy:
        pct(duplicateCorrect.length,duplicateRows.length),
      reasonFamilyAccuracy:
        pct(reasonCorrect.length,reasonEligible.length),
      evidenceCoverage:
        pct(evidenceComplete.length,fixtures.length),
      replayCoverage:replaySame?100:0
    };

    const passive:any[]=[];
    const gate=(name:string,ok:boolean,detail:any={})=>
      passive.push({name,ok,detail});

    gate(
      'r1d_exact_binding',
      binding.certification_status==='CERTIFIED'
      &&binding.certification_version==='r1d-v2.0.0',
      binding
    );

    gate(
      'ruleset_sha',
      ruleset.rules_sha256===
        (await c.query(
          `select retail.r1e_sha256_jsonb($1::jsonb) h`,
          [JSON.stringify(ruleset.rules_json)]
        )).rows[0].h
    );

    gate(
      'minimum_total_fixtures',
      fixtures.length>=Number(p.minimum_total_fixtures),
      {actual:fixtures.length,required:p.minimum_total_fixtures}
    );

    for(const [cls,min] of Object.entries(p.class_minimums||{})){
      gate(
        `class_minimum_${cls}`,
        (classCounts[cls]??0)>=Number(min),
        {actual:classCounts[cls]??0,required:min}
      );
    }

    gate(
      'decision_accuracy',
      metrics.decisionAccuracy>=Number(p.minimum_decision_accuracy),
      metrics
    );
    gate(
      'positive_precision',
      metrics.positivePrecision>=Number(p.minimum_positive_precision),
      metrics
    );
    gate(
      'positive_recall',
      metrics.positiveRecall>=Number(p.minimum_positive_recall),
      metrics
    );
    gate(
      'false_positive_rate',
      metrics.falsePositiveRate<=Number(p.maximum_false_positive_rate),
      metrics
    );
    gate(
      'wrong_variant_fpr',
      metrics.wrongVariantFalsePositiveRate<=
        Number(p.maximum_wrong_variant_fpr),
      metrics
    );
    gate(
      'duplicate_accuracy',
      metrics.duplicateAccuracy>=Number(p.minimum_duplicate_accuracy),
      metrics
    );
    gate(
      'reason_family_accuracy',
      metrics.reasonFamilyAccuracy>=
        Number(p.minimum_reason_family_accuracy),
      metrics
    );
    gate(
      'evidence_coverage',
      metrics.evidenceCoverage>=Number(p.minimum_evidence_coverage),
      metrics
    );
    gate(
      'deterministic_replay',
      metrics.replayCoverage>=Number(p.minimum_replay_coverage),
      metrics
    );

    const adversarial=runJson(
      'scripts/retail-automation/r1e/adversarial-tests-v21.ts',
      [rulesetId]
    );

    const e2e=runJson(
      'scripts/retail-automation/r1e/e2e-tests.ts',
      [rulesetId]
    );

    const concurrency=runJson(
      'scripts/retail-automation/r1e/duplicate-concurrency-tests.ts',
      [rulesetId]
    );

    const e2eResults=Array.isArray(e2e.results)?e2e.results:[];
    const e2ePassed=e2eResults.filter((x:any)=>x.ok).length;
    const e2eAccuracy=pct(e2ePassed,e2eResults.length);

    gate(
      'minimum_e2e_fixtures',
      e2eResults.length>=Number(p.minimum_e2e_fixtures),
      {actual:e2eResults.length,required:p.minimum_e2e_fixtures}
    );
    gate(
      'e2e_accuracy',
      e2eAccuracy>=Number(p.minimum_e2e_accuracy),
      {actual:e2eAccuracy,required:p.minimum_e2e_accuracy}
    );

    const pureFixtureManifest=fixtures.map((f:any)=>({
      fixtureCode:f.fixture_code,
      fixtureSha256:f.fixture_sha256,
      fixtureClass:f.fixture_class,
      expectedDecision:f.expected_decision,
      expectedReasonFamily:f.expected_reason_family,
      actualDecision:f.result?.decision,
      actualReasonCodes:f.result?.reason_codes,
      resultSha256:f.result_sha
    }));

    const e2eFixtureManifest=e2eResults.map((f:any)=>({
      fixtureCode:f.fixtureCode,
      fixtureSha256:f.fixtureSha256,
      fixtureClass:f.fixtureClass,
      expectedDecision:f.expectedDecision,
      expectedReasonFamily:f.expectedReasonFamily,
      actualDecision:f.actualDecision,
      reasonCodes:f.reasonCodes,
      resultId:f.resultId,
      observationFingerprint:f.observationFingerprint,
      ok:f.ok
    }));

    const e2eFixtureManifestSha256=sha(
      Buffer.from(canonicalStringify(e2eFixtureManifest),'utf8')
    );

    const pass=
      passive.every(x=>x.ok)
      &&adversarial.allPassed===true
      &&e2e.allPassed===true
      &&concurrency.allPassed===true;

    const evidence={
      certificationVersion:'r1e-v2.1.0',
      processRunId:runId,
      correlationId,
      createdAt:new Date().toISOString(),
      r1dBinding:binding,
      r1ePackageZip:path.basename(packageFile!),
      r1ePackageSha256:releaseSha,
      rulesetId,
      rulesetSha256:ruleset.rules_sha256,
      certificationPolicyId:policy.id,
      certificationPolicySha256:policy.policy_sha256,
      metrics,
      passiveResults:passive,
      adversarialResults:adversarial.gates??[],
      e2eResults,
      duplicateConcurrencyResults:concurrency.gates??[],
      duplicateConcurrencyFixture:{
        fixtureCode:concurrency.fixtureCode??null,
        fixtureSha256:concurrency.fixtureSha256??null
      },
      pureFixtureManifest,
      e2eFixtureManifest,
      e2eFixtureManifestSha256
    };

    const canonicalText=canonicalStringify(evidence);
    const seal=sha(Buffer.from(canonicalText,'utf8'));

    await writeFile(outFile,JSON.stringify({
      manifest:canonicalize(evidence),
      canonicalManifestText:canonicalText,
      evidenceManifestSha256:seal
    },null,2));

    const adversarialGates=adversarial.gates??[];
    const concurrencyGates=concurrency.gates??[];
    const totalGates=
      passive.length+
      adversarialGates.length+
      concurrencyGates.length+
      e2eResults.length;

    const passedGates=
      passive.filter(x=>x.ok).length+
      adversarialGates.filter((x:any)=>x.ok).length+
      concurrencyGates.filter((x:any)=>x.ok).length+
      e2eResults.filter((x:any)=>x.ok).length;

    await c.query('begin');
    try{
      await c.query(`
        insert into retail.r1e_certification_runs(
          process_run_id,certification_version,
          r1d_certification_run_id,r1d_package_sha256,
          r1e_package_sha256,
          ruleset_id,ruleset_sha256,
          passive_results,active_results,replay_results,
          evidence_manifest,evidence_manifest_text,
          evidence_manifest_sha256,
          total_gates,passed_gates,failed_gates,
          certification_status,certified_by,
          certification_policy_id,certification_policy_sha256,
          e2e_results,e2e_fixture_manifest_sha256
        ) values(
          $1,'r1e-v2.1.0',$2,$3,$4,$5,$6,
          $7::jsonb,$8::jsonb,$9::jsonb,
          $10::jsonb,$11,$12,
          $13,$14,$15,$16,$17,$18,$19,
          $20::jsonb,$21
        )
      `,[
        runId,
        binding.r1d_certification_run_id,
        binding.r1d_package_sha256,
        releaseSha,
        rulesetId,
        ruleset.rules_sha256,
        JSON.stringify(passive),
        JSON.stringify({
          adversarial:adversarialGates,
          duplicateConcurrency:concurrencyGates,
          duplicateConcurrencyFixture:{
            fixtureCode:concurrency.fixtureCode??null,
            fixtureSha256:concurrency.fixtureSha256??null
          }
        }),
        JSON.stringify({metrics,replaySame}),
        canonicalText,
        canonicalText,
        seal,
        totalGates,
        passedGates,
        totalGates-passedGates,
        pass?'CERTIFIED':'FAILED',
        actor,
        policy.id,
        policy.policy_sha256,
        JSON.stringify({
          allPassed:e2e.allPassed===true,
          total:e2eResults.length,
          passed:e2ePassed,
          accuracy:e2eAccuracy,
          fixtureManifest:e2eFixtureManifest
        }),
        e2eFixtureManifestSha256
      ]);

      await c.query(`
        update arb.process_runs
        set status=$2,
            certification_status=$3,
            certification_report_json=$4::jsonb,
            completed_at=case when $2='SUCCEEDED' then now() else completed_at end,
            failed_at=case when $2='FAILED' then now() else failed_at end,
            updated_at=now()
        where run_id=$1
      `,[
        runId,
        pass?'SUCCEEDED':'FAILED',
        pass?'CERTIFIED':'FAILED',
        JSON.stringify({
          packageSha256:releaseSha,
          evidenceManifestSha256:seal,
          policySha256:policy.policy_sha256,
          e2eFixtureManifestSha256,
          metrics,
          e2eAccuracy,
          adversarialPass:adversarial.allPassed===true,
          e2ePass:e2e.allPassed===true,
          concurrencyPass:concurrency.allPassed===true
        })
      ]);

      await c.query('commit');
    }catch(e){
      await c.query('rollback').catch(()=>undefined);
      throw e;
    }

    console.log(JSON.stringify({
      certification:pass?'CERTIFIED':'FAILED',
      certificationVersion:'r1e-v2.1.0',
      processRunId:runId,
      packageSha256:releaseSha,
      evidenceManifestSha256:seal,
      e2eFixtureManifestSha256,
      policySha256:policy.policy_sha256,
      metrics,
      e2eAccuracy,
      passive,
      adversarial,
      e2eSummary:{
        allPassed:e2e.allPassed===true,
        total:e2eResults.length,
        passed:e2ePassed
      },
      concurrency
    },null,2));

    if(!pass) process.exitCode=2;
  }catch(e){
    if(runId){
      await c.query(`
        update arb.process_runs
        set status='FAILED',
            certification_status='FAILED',
            error_summary=$2,
            failed_at=now(),
            updated_at=now()
        where run_id=$1
      `,[
        runId,
        String((e as Error).message??e).slice(0,2000)
      ]).catch(()=>undefined);
    }
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}

main().catch(e=>{
  console.error(e);
  process.exitCode=1;
});
