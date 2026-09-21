import { Pool } from 'pg';
import { createHash,randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFile,writeFile } from 'node:fs/promises';
import path from 'node:path';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [policyId]=process.argv.slice(2);
const packageFile=process.env.R1F_PACKAGE_ZIP;
const actor=process.env.R1F_CERTIFIER||'R1F V2 Certification Authority';
const outFile=process.env.R1F_CERT_EVIDENCE_OUT||
  'r1f-v2-certification-evidence.json';

if(!policyId||!packageFile){
  throw new Error(
    'usage: R1F_PACKAGE_ZIP=<exact-release.zip> tsx certify.ts <intelligence_policy_uuid>'
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
const pct=(a:number,b:number)=>b?100*a/b:0;

function runJson(script:string,args:string[]=[]){
  try{
    const raw=execFileSync(
      process.execPath,['--import','tsx',script,...args],
      {cwd:process.env.REPO_ROOT??process.cwd(),encoding:'utf8',env:process.env}
    );
    return JSON.parse(raw);
  }catch(e:any){
    return {
      allPassed:false,
      error:String(e?.stderr||e?.message||e),
      gates:[],
      scenarios:[]
    };
  }
}

async function main(){
  const releaseSha=sha(await readFile(path.resolve(packageFile!)));
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
        'RETAIL_R1F_CERTIFY','FREEZE_GATE','STARTED',$1,
        'system','r1f-v2-certifier',$2,
        'r1f-v2-certify',$3,$4,'r1f-v2.0.0',
        'retail.r1f',$5
      ) returning run_id
    `,[
      correlationId,actor,
      process.env.WORKER_INSTANCE_ID??'r1f-v2-cert-1',
      process.env.CODE_VERSION??'unknown',
      `R1F_V2_CERT:${correlationId}`
    ]);
    runId=run.rows[0].run_id;

    const binding=(await c.query(`
      select b.*,cr.certification_status,cr.certification_version
      from retail.r1f_r1e_certification_binding b
      join retail.r1e_certification_runs cr
        on cr.id=b.r1e_certification_run_id
      where b.singleton=true
    `)).rows[0];

    if(!binding||
       (await c.query(`select retail.r1f_r1e_binding_is_current() ok`))
         .rows[0].ok!==true){
      throw new Error('Exact current R1E V2.1 binding missing/stale');
    }

    const policy=(await c.query(`
      select * from retail.r1f_intelligence_policies
      where id=$1 and certification_status='certified'
    `,[policyId])).rows[0];
    if(!policy) throw new Error('Certified R1F V2 intelligence policy required');

    await c.query(`select retail.r1f_validate_policy($1::jsonb)`,[
      JSON.stringify(policy.policy_json)
    ]);

    const certPolicy=(await c.query(`
      select * from retail.r1f_certification_policies
      where certification_status='certified'
      order by certified_at desc,id::text desc
      limit 1
    `)).rows[0];
    if(!certPolicy){
      throw new Error('Certified R1F V2 Green Tier certification policy required');
    }

    await c.query(
      `select retail.r1f_validate_certification_policy($1::jsonb)`,
      [JSON.stringify(certPolicy.policy_json)]
    );

    const fixtures=(await c.query(`
      select *
      from retail.r1f_qa_fixtures
      where active=true
      order by fixture_code
    `)).rows;

    const classCounts:Record<string,number>={};
    const fixtureResults:any[]=[];

    for(const f of fixtures){
      await c.query(`
        select retail.r1f_validate_qa_fixture($1,$2::jsonb,$3::jsonb)
      `,[f.fixture_class,JSON.stringify(f.input_json),JSON.stringify(f.expected_json)]);

      classCounts[f.fixture_class]=(classCounts[f.fixture_class]??0)+1;
      let actual:any;
      let ok=false;

      if(f.fixture_class==='nationwide_ranking'){
        const ranked=(await c.query(`
          select retail.r1f_rank_locations($1::jsonb,$2::jsonb) r
        `,[
          JSON.stringify(f.input_json.locations),
          JSON.stringify(policy.policy_json)
        ])).rows[0].r;

        const actualOrder=ranked.map((x:any)=>x.location_code);
        const expectedOrder=f.expected_json.ordered_location_codes;
        ok=JSON.stringify(actualOrder)===JSON.stringify(expectedOrder);
        actual={ranked,actualOrder};
      }else if(f.fixture_class==='strategy_convergence'){
        const simulation=(await c.query(`
          select retail.r1f_simulate_strategy($1::jsonb,$2::jsonb) r
        `,[
          JSON.stringify(f.input_json.cycles),
          JSON.stringify(policy.policy_json)
        ])).rows[0].r;

        ok=JSON.stringify(simulation)===
          JSON.stringify(f.expected_json.expected_cycle_recommendations);
        actual={simulation};
      }else{
        const score=(await c.query(`
          select retail.r1f_score_document_v2($1::jsonb,$2::jsonb) r
        `,[
          JSON.stringify(f.input_json.metrics),
          JSON.stringify(policy.policy_json)
        ])).rows[0].r;

        const decision=(await c.query(`
          select retail.r1f_recommendation_decision($1::jsonb,$2::jsonb) r
        `,[
          JSON.stringify({
            ...(f.input_json.snapshot??{}),
            opportunity_score:score.opportunity_score
          }),
          JSON.stringify(policy.policy_json)
        ])).rows[0].r;

        const e=f.expected_json;
        const checks:any[]=[];

        if(e.recommendation_type!==undefined){
          checks.push(decision.recommendation_type===e.recommendation_type);
        }
        if(e.minimum_opportunity_score!==undefined){
          checks.push(Number(score.opportunity_score)>=Number(e.minimum_opportunity_score));
        }
        if(e.maximum_opportunity_score!==undefined){
          checks.push(Number(score.opportunity_score)<=Number(e.maximum_opportunity_score));
        }
        if(e.minimum_bargain_score!==undefined){
          checks.push(Number(score.bargain_score)>=Number(e.minimum_bargain_score));
        }
        if(e.maximum_cost_efficiency_score!==undefined){
          checks.push(
            Number(score.cost_efficiency_score)<=Number(e.maximum_cost_efficiency_score)
          );
        }
        if(e.maximum_availability_score!==undefined){
          checks.push(
            Number(score.availability_score)<=Number(e.maximum_availability_score)
          );
        }

        ok=checks.length>0&&checks.every(Boolean);
        actual={score,decision};
      }

      const replay1=sha(Buffer.from(canonicalStringify(actual),'utf8'));

      let actual2:any;
      if(f.fixture_class==='nationwide_ranking'){
        actual2={
          ranked:(await c.query(`
            select retail.r1f_rank_locations($1::jsonb,$2::jsonb) r
          `,[JSON.stringify(f.input_json.locations),JSON.stringify(policy.policy_json)]))
            .rows[0].r
        };
        actual2.actualOrder=actual2.ranked.map((x:any)=>x.location_code);
      }else if(f.fixture_class==='strategy_convergence'){
        actual2={
          simulation:(await c.query(`
            select retail.r1f_simulate_strategy($1::jsonb,$2::jsonb) r
          `,[JSON.stringify(f.input_json.cycles),JSON.stringify(policy.policy_json)]))
            .rows[0].r
        };
      }else{
        const score2=(await c.query(`
          select retail.r1f_score_document_v2($1::jsonb,$2::jsonb) r
        `,[JSON.stringify(f.input_json.metrics),JSON.stringify(policy.policy_json)]))
          .rows[0].r;
        const decision2=(await c.query(`
          select retail.r1f_recommendation_decision($1::jsonb,$2::jsonb) r
        `,[
          JSON.stringify({
            ...(f.input_json.snapshot??{}),
            opportunity_score:score2.opportunity_score
          }),
          JSON.stringify(policy.policy_json)
        ])).rows[0].r;
        actual2={score:score2,decision:decision2};
      }

      const replay2=sha(Buffer.from(canonicalStringify(actual2),'utf8'));
      const replayOk=replay1===replay2;

      fixtureResults.push({
        fixtureCode:f.fixture_code,
        fixtureClass:f.fixture_class,
        fixtureSha256:f.fixture_sha256,
        expected:f.expected_json,
        actual,
        resultSha256:replay1,
        replayOk,
        ok:ok&&replayOk
      });
    }

    const cp=certPolicy.policy_json;
    const passive:any[]=[];
    const gate=(name:string,ok:boolean,detail:any={})=>
      passive.push({name,ok,detail});

    gate('r1e_exact_binding',
      binding.certification_status==='CERTIFIED'
      &&binding.certification_version==='r1e-v2.1.0');

    gate('minimum_total_fixtures',
      fixtures.length>=Number(cp.minimum_total_fixtures),
      {actual:fixtures.length,required:cp.minimum_total_fixtures});

    for(const [cls,min] of Object.entries(cp.class_minimums||{})){
      gate(`class_minimum_${cls}`,
        (classCounts[cls]??0)>=Number(min),
        {actual:classCounts[cls]??0,required:min});
    }

    const ordinary=fixtureResults.filter(
      x=>!['nationwide_ranking','strategy_convergence'].includes(x.fixtureClass)
    );
    const ranking=fixtureResults.filter(x=>x.fixtureClass==='nationwide_ranking');
    const convergence=fixtureResults.filter(x=>x.fixtureClass==='strategy_convergence');

    const scoreAccuracy=pct(ordinary.filter(x=>x.ok).length,ordinary.length);
    const rankingAccuracy=pct(ranking.filter(x=>x.ok).length,ranking.length);
    const convergenceAccuracy=pct(
      convergence.filter(x=>x.ok).length,convergence.length
    );
    const replayCoverage=pct(
      fixtureResults.filter(x=>x.replayOk).length,fixtureResults.length
    );

    gate('score_and_recommendation_accuracy',
      scoreAccuracy>=Number(cp.minimum_score_accuracy)
      &&scoreAccuracy>=Number(cp.minimum_recommendation_accuracy),
      {actual:scoreAccuracy});

    gate('ranking_accuracy',
      rankingAccuracy>=Number(cp.minimum_ranking_accuracy),
      {actual:rankingAccuracy,required:cp.minimum_ranking_accuracy});

    gate('convergence_accuracy',
      convergenceAccuracy>=Number(cp.minimum_convergence_accuracy),
      {actual:convergenceAccuracy,required:cp.minimum_convergence_accuracy});

    gate('replay_coverage',
      replayCoverage>=Number(cp.minimum_replay_coverage),
      {actual:replayCoverage,required:cp.minimum_replay_coverage});

    const adversarial=runJson(
      'scripts/retail-automation/r1f/adversarial-tests-v2.ts',
      [policyId]
    );
    const e2e=runJson('scripts/retail-automation/r1f/e2e-tests.ts');
    const concurrency=runJson(
      'scripts/retail-automation/r1f/recommendation-concurrency-tests.ts'
    );

    const e2eScenarios=Array.isArray(e2e.scenarios)?e2e.scenarios:[];
    const e2eJobs=Number(e2e.totalJobs??0);
    const e2eAccuracy=pct(e2eScenarios.filter((x:any)=>x.ok).length,e2eScenarios.length);

    gate('minimum_e2e_scenarios',
      e2eScenarios.length>=Number(cp.minimum_e2e_scenarios),
      {actual:e2eScenarios.length,required:cp.minimum_e2e_scenarios});
    gate('minimum_e2e_jobs',
      e2eJobs>=Number(cp.minimum_e2e_jobs),
      {actual:e2eJobs,required:cp.minimum_e2e_jobs});
    gate('e2e_accuracy',
      e2eAccuracy>=Number(cp.minimum_e2e_accuracy),
      {actual:e2eAccuracy,required:cp.minimum_e2e_accuracy});

    // Zero-row bypass is prohibited. These are actual V2 certification-pipeline rows.
    const coverage=(await c.query(`
      select
        (select count(*)::int from retail.r1f_job_facts
          where engine_version='r1f-v2.0.0' and certification_fixture=true) facts,
        (select count(*)::int from retail.r1f_observation_facts
          where engine_version='r1f-v2.0.0' and certification_fixture=true) observations,
        (select count(*)::int from retail.r1f_intelligence_snapshots
          where engine_version='r1f-v2.0.0' and certification_fixture=true) snapshots,
        (select count(*)::int from retail.r1f_search_recommendations
          where engine_version='r1f-v2.0.0' and certification_fixture=true) recommendations,
        (select count(*)::int from retail.r1f_job_facts
          where engine_version='r1f-v2.0.0' and certification_fixture=true
            and fact_sha256=retail.r1f_sha256_jsonb(fact_document)) valid_facts,
        (select count(*)::int from retail.r1f_intelligence_snapshots
          where engine_version='r1f-v2.0.0' and certification_fixture=true
            and intelligence_sha256=retail.r1f_sha256_jsonb(intelligence_document))
          valid_snapshots,
        (select count(*)::int from retail.r1f_search_recommendations
          where engine_version='r1f-v2.0.0' and certification_fixture=true
            and recommendation_sha256=retail.r1f_sha256_jsonb(recommendation_document))
          valid_recommendations
    `)).rows[0];

    const factHashCoverage=pct(Number(coverage.valid_facts),Number(coverage.facts));
    const snapshotHashCoverage=pct(
      Number(coverage.valid_snapshots),Number(coverage.snapshots)
    );
    const recHashCoverage=pct(
      Number(coverage.valid_recommendations),Number(coverage.recommendations)
    );

    gate('nonzero_full_pipeline_rows',
      Number(coverage.facts)>0
      &&Number(coverage.observations)>0
      &&Number(coverage.snapshots)>0
      &&Number(coverage.recommendations)>0,
      coverage);

    gate('fact_hash_coverage',
      factHashCoverage>=Number(cp.minimum_fact_hash_coverage),
      {actual:factHashCoverage});
    gate('snapshot_hash_coverage',
      snapshotHashCoverage>=Number(cp.minimum_snapshot_hash_coverage),
      {actual:snapshotHashCoverage});
    gate('recommendation_hash_coverage',
      recHashCoverage>=Number(cp.minimum_recommendation_hash_coverage),
      {actual:recHashCoverage});

    const quality=(await c.query(`
      select
        count(*) filter(
          where collection_reconciliation_status='MATCHED'
        )::numeric/nullif(count(*),0) reconciliation_coverage,
        count(*) filter(
          where cost_basis in('actual','allocated_provider')
        )::numeric/nullif(count(*),0) actual_cost_coverage,
        count(*) filter(
          where (
            COALESCE(location_type,'national')
              not in('metro','postal_code','store')
            or location_timezone is not null
          )
        )::numeric/nullif(count(*),0) timezone_coverage
      from retail.r1f_job_facts
      where engine_version='r1f-v2.0.0'
        and certification_fixture=true
    `)).rows[0];

    gate('collection_reconciliation_100',
      Number(quality.reconciliation_coverage)===1,
      quality);
    gate('actual_cost_coverage',
      Number(quality.actual_cost_coverage)>=
        Number(cp.minimum_actual_cost_coverage_pct)/100,
      quality);

    const financial=(await c.query(`
      with cf as (
        select * from retail.r1f_job_facts
        where engine_version='r1f-v2.0.0'
          and certification_fixture=true
      ), used_periods as (
        select distinct a.authority_period_id
        from cf f
        join retail.r1f_provider_job_cost_allocations_v22 a
          on a.r1d_job_id=f.r1d_job_id
        where f.cost_authority in(
          'BRIGHT_DATA_ZONE_COST','BRIGHT_DATA_COST_BREAKDOWN',
          'BRIGHT_DATA_SNAPSHOT_DIRECT'
        )
      ), balances as (
        select p.id period_id,p.billed_cost_usd,
               coalesce(sum(a.allocated_provider_cost_usd),0)::numeric allocated_cost_usd
        from retail.r1f_provider_cost_authority_periods p
        join used_periods u on u.authority_period_id=p.id
        left join retail.r1f_provider_job_cost_allocations_v22 a
          on a.authority_period_id=p.id
        group by p.id,p.billed_cost_usd
      )
      select
        count(*)::int total_jobs,
        count(*) filter(where cost_authority in('BRIGHT_DATA_ZONE_COST','BRIGHT_DATA_COST_BREAKDOWN','BRIGHT_DATA_SNAPSHOT_DIRECT'))::int provider_reconciled_jobs,
        count(*) filter(where cost_authority in('BRIGHT_DATA_ZONE_COST','BRIGHT_DATA_COST_BREAKDOWN','BRIGHT_DATA_SNAPSHOT_DIRECT'))::numeric/nullif(count(*),0) provider_reconciled_coverage,
        count(*) filter(where provider_financial_verification_status='PROVIDER_PAID_COST_RECONCILED')::int paid_provider_jobs,
        count(*) filter(where provider_financial_verification_status='PROVIDER_ZERO_COST_CONFIRMED')::int zero_cost_provider_jobs,
        count(*) filter(where provider_usage_verification_status in('PROVIDER_USAGE_CONFIRMED','PROVIDER_USAGE_ZERO'))::numeric/nullif(count(*),0) provider_usage_verified_coverage,
        (select count(*) from balances)::int used_provider_periods,
        (select count(*) from balances where round(billed_cost_usd,8)=round(allocated_cost_usd,8))::int balanced_provider_periods,
        case when (select count(*) from balances)=0 then 0
             else (select count(*) from balances where round(billed_cost_usd,8)=round(allocated_cost_usd,8))::numeric/(select count(*) from balances) end reconciliation_balance_coverage
      from cf
    `)).rows[0];

    gate('provider_reconciled_cost_coverage',
      Number(financial.provider_reconciled_coverage)>=
        Number(cp.minimum_provider_reconciled_cost_coverage_pct)/100,
      financial);
    gate('provider_reconciliation_balance',
      Number(financial.reconciliation_balance_coverage)>=
        Number(cp.minimum_provider_reconciliation_balance_pct)/100,
      financial);
    gate('provider_usage_verified_coverage_100',
      Number(financial.provider_usage_verified_coverage)===1,
      financial);
    gate('provider_paid_cost_sample',
      Number(financial.paid_provider_jobs)>=
        Number(cp.minimum_provider_paid_cost_sample_jobs??1),
      financial);

    const finIntegrity=(await c.query(`
      select
        count(*)::int reconciled,
        count(*) filter(where
          (
            (p.authority_source_type='ZONE_COST'
              and e.id is not null
              and b.id is not null
              and e.raw_payload_sha256=retail.r1f_sha256_jsonb(e.raw_payload)
              and b.bucket_sha256=retail.r1f_sha256_jsonb(b.bucket_document))
            or
            (p.authority_source_type='COST_BREAKDOWN'
              and ce.id is not null
              and dr.id is not null
              and ce.raw_payload_sha256=retail.r1f_sha256_jsonb(ce.raw_payload)
              and dr.resource_sha256=retail.r1f_sha256_jsonb(dr.resource_document))
          )
          and p.semantics_sha256=retail.r1f_sha256_jsonb(p.semantics_evidence)
          and p.authority_sha256=retail.r1f_sha256_jsonb(p.authority_document)
          and x.allocation_sha256=retail.r1f_sha256_jsonb(x.allocation_document)
          and r.receipt_sha256=retail.r1f_sha256_jsonb(r.receipt_document)
          and s.financial_identity_sha256=retail.r1f_sha256_jsonb(s.financial_identity_document)
        )::int valid
      from retail.r1f_provider_job_cost_allocations_v22 x
      join retail.r1f_provider_cost_authority_periods p on p.id=x.authority_period_id
      left join retail.r1f_provider_cost_evidence e on e.id=p.evidence_id
      left join retail.r1f_provider_cost_buckets b on b.id=p.bucket_id
      left join retail.r1f_provider_cost_breakdown_evidence ce on ce.id=p.cost_breakdown_evidence_id
      left join retail.r1f_provider_daily_resource_costs dr on dr.id=p.daily_resource_cost_id
      join retail.r1f_job_provider_execution_receipts r on r.id=x.execution_receipt_id
      join retail.r1f_scraper_financial_registry s on s.id=x.scraper_registry_id
      join retail.r1f_job_facts f on f.r1d_job_id=x.r1d_job_id
      where f.engine_version='r1f-v2.0.0'
        and f.certification_fixture=true
        and f.cost_authority in(
          'BRIGHT_DATA_ZONE_COST','BRIGHT_DATA_COST_BREAKDOWN',
          'BRIGHT_DATA_SNAPSHOT_DIRECT'
        )
    `)).rows[0];
    gate('provider_financial_evidence_hash_integrity_100',
      Number(finIntegrity.reconciled)>0
      &&Number(finIntegrity.valid)===Number(finIntegrity.reconciled),
      finIntegrity);

    const finGlobal=(await c.query(`
      select * from retail.r1f_financial_v22_global_integrity
    `)).rows[0];
    const expectedScrapers=Number(finGlobal?.expected_scraper_count);
    gate('current_r1d_scraper_scope_complete',
      expectedScrapers>0
      &&Number(finGlobal?.discovered_scraper_count)===expectedScrapers
      &&Number(finGlobal?.active_scrapers)===expectedScrapers,
      finGlobal);
    gate('scraper_registry_hash_integrity_100',
      Number(finGlobal?.registry_hash_valid)===expectedScrapers,
      finGlobal);
    gate('all_current_scrapers_have_execution_receipts',
      Number(finGlobal?.scrapers_with_receipts)===expectedScrapers,
      finGlobal);
    gate('all_current_scrapers_have_provider_cost_allocations',
      Number(finGlobal?.scrapers_with_allocations)===expectedScrapers,
      finGlobal);
    gate('financial_global_hygiene',
      Number(finGlobal?.orphan_unreconciled_bindings)===0
      &&Number(finGlobal?.unreconciled_authority_periods)===0
      &&Number(finGlobal?.provider_periods)>0
      &&Number(finGlobal?.balanced_provider_periods)===Number(finGlobal?.provider_periods),
      finGlobal);
    gate('local_timezone_coverage',
      Number(quality.timezone_coverage)>=
        Number(cp.minimum_local_timezone_coverage_pct)/100,
      quality);

    const economic=(await c.query(`
      select
        count(*)::int total,
        count(*) filter(
          where currency_code='USD'
            and economic_amount is not null
            and condition_normalized is not null
            and fulfillment_mode is not null
        )::int valid
      from retail.r1f_observation_facts
      where engine_version='r1f-v2.0.0'
        and certification_fixture=true
    `)).rows[0];

    gate('economic_dimension_coverage_100',
      Number(economic.total)>0
      &&Number(economic.valid)===Number(economic.total),
      economic);

    const e2eManifest=e2eScenarios.map((x:any)=>({
      scenarioCode:x.scenarioCode,
      scenarioId:x.scenarioId,
      fixtureSha256:x.fixtureSha256,
      chainManifest:x.chainManifest,
      ok:x.ok
    }));
    const e2eManifestSha256=sha(
      Buffer.from(canonicalStringify(e2eManifest),'utf8')
    );

    const pass=
      passive.every(x=>x.ok)
      &&fixtureResults.every(x=>x.ok)
      &&adversarial.allPassed===true
      &&e2e.allPassed===true
      &&concurrency.allPassed===true;

    const evidence={
      certificationVersion:'r1f-v2.0.0',
      processRunId:runId,
      correlationId,
      createdAt:new Date().toISOString(),
      r1eBinding:binding,
      r1fPackageZip:path.basename(packageFile!),
      r1fPackageSha256:releaseSha,
      intelligencePolicyId:policy.id,
      intelligencePolicySha256:policy.policy_sha256,
      certificationPolicyId:certPolicy.id,
      certificationPolicySha256:certPolicy.policy_sha256,
      fixtureManifest:fixtureResults.map(x=>({
        fixtureCode:x.fixtureCode,
        fixtureClass:x.fixtureClass,
        fixtureSha256:x.fixtureSha256,
        expected:x.expected,
        resultSha256:x.resultSha256,
        ok:x.ok
      })),
      e2eManifest,
      e2eManifestSha256,
      metrics:{
        fixtureCount:fixtures.length,
        classCounts,
        scoreAccuracy,
        rankingAccuracy,
        convergenceAccuracy,
        replayCoverage,
        e2eScenarioCount:e2eScenarios.length,
        e2eJobs,
        e2eAccuracy,
        factHashCoverage,
        snapshotHashCoverage,
        recommendationHashCoverage:recHashCoverage
      },
      passiveResults:passive,
      adversarialResults:adversarial.gates??[],
      concurrencyResults:concurrency.gates??[]
    };

    const canonicalText=canonicalStringify(evidence);
    const seal=sha(Buffer.from(canonicalText,'utf8'));

    await writeFile(outFile,JSON.stringify({
      manifest:canonicalize(evidence),
      canonicalManifestText:canonicalText,
      evidenceManifestSha256:seal
    },null,2));

    const activeGates=adversarial.gates??[];
    const concurrencyGates=concurrency.gates??[];
    const totalGates=
      passive.length+fixtureResults.length+
      activeGates.length+concurrencyGates.length+e2eScenarios.length;
    const passedGates=
      passive.filter(x=>x.ok).length+
      fixtureResults.filter(x=>x.ok).length+
      activeGates.filter((x:any)=>x.ok).length+
      concurrencyGates.filter((x:any)=>x.ok).length+
      e2eScenarios.filter((x:any)=>x.ok).length;

    await c.query('begin');
    try{
      await c.query(`
        insert into retail.r1f_certification_runs(
          process_run_id,certification_version,
          r1e_certification_run_id,r1e_package_sha256,
          r1f_package_sha256,
          policy_id,policy_sha256,
          certification_policy_id,certification_policy_sha256,
          passive_results,active_results,replay_results,
          evidence_manifest,evidence_manifest_text,evidence_manifest_sha256,
          total_gates,passed_gates,failed_gates,
          certification_status,certified_by,
          e2e_results,e2e_manifest_sha256,
          ranking_results,convergence_results,concurrency_results
        ) values(
          $1,'r1f-v2.0.0',$2,$3,$4,$5,$6,$7,$8,
          $9::jsonb,$10::jsonb,$11::jsonb,
          $12::jsonb,$13,$14,$15,$16,$17,$18,$19,
          $20::jsonb,$21,$22::jsonb,$23::jsonb,$24::jsonb
        )
      `,[
        runId,binding.r1e_certification_run_id,binding.r1e_package_sha256,
        releaseSha,policy.id,policy.policy_sha256,
        certPolicy.id,certPolicy.policy_sha256,
        JSON.stringify(passive),
        JSON.stringify(activeGates),
        JSON.stringify({replayCoverage}),
        canonicalText,canonicalText,seal,
        totalGates,passedGates,totalGates-passedGates,
        pass?'CERTIFIED':'FAILED',actor,
        JSON.stringify({
          allPassed:e2e.allPassed===true,
          scenarioCount:e2eScenarios.length,
          totalJobs:e2eJobs,
          accuracy:e2eAccuracy
        }),
        e2eManifestSha256,
        JSON.stringify({allPassed:rankingAccuracy===100,accuracy:rankingAccuracy}),
        JSON.stringify({
          allPassed:convergenceAccuracy===100,
          accuracy:convergenceAccuracy
        }),
        JSON.stringify(concurrency)
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
          e2eManifestSha256,
          metrics:evidence.metrics,
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
      certificationVersion:'r1f-v2.0.0',
      processRunId:runId,
      packageSha256:releaseSha,
      evidenceManifestSha256:seal,
      e2eManifestSha256,
      metrics:evidence.metrics,
      passive,
      adversarial,
      concurrency,
      e2eSummary:{
        allPassed:e2e.allPassed===true,
        scenarios:e2eScenarios.length,
        jobs:e2eJobs,
        accuracy:e2eAccuracy
      }
    },null,2));

    if(!pass) process.exitCode=2;
  }catch(e){
    if(runId){
      await c.query(`
        update arb.process_runs
        set status='FAILED',certification_status='FAILED',
            error_summary=$2,failed_at=now(),updated_at=now()
        where run_id=$1
      `,[runId,String((e as Error).message??e).slice(0,2000)])
        .catch(()=>undefined);
    }
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}

main().catch(e=>{console.error(e);process.exitCode=1;});
