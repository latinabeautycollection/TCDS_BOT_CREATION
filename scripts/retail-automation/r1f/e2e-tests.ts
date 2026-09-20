import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL,max:8});

async function main(){
  const scenarios=await pool.query(`
    select *
    from retail.r1f_e2e_qa_scenarios
    where active=true
      and scenario_type='E2E'
    order by window_end,scenario_code
  `);

  if(!scenarios.rowCount){
    throw new Error('R1F V2 E2E scenarios are required');
  }

  const scenarioResults:any[]=[];
  let totalJobs=0;
  let failed=0;

  for(const s of scenarios.rows){
    totalJobs+=s.job_ids.length;

    const run=await startPersistentRun(
      pool,'RETAIL_R1F_V2_E2E_CERTIFY','system',
      `r1f-v2-e2e-${s.scenario_code}`,
      `R1F V2 E2E ${s.scenario_code}`,
      'retail.r1f',
      'E2E_CERTIFICATION'
    );

    const errors:any[]=[];

    try{
      for(const jobId of s.job_ids){
        try{
          await pool.query(`
            select retail.r1f_ingest_completed_job_v2(
              $1,$2,$3,$4,true,$5
            )
          `,[
            jobId,run.runId,run.correlationId,
            `R1F V2 E2E ${s.scenario_code}`,
            s.id
          ]);
        }catch(e){
          errors.push({
            step:'ingest',
            jobId,
            error:String((e as Error).message??e)
          });
        }
      }

      if(!errors.length){
        try{
          await pool.query(`
            select retail.r1f_build_intelligence_v2(
              $1,$2,$3,$4,$5,true,$6
            )
          `,[
            s.intelligence_policy_id,
            s.window_end,
            run.runId,
            run.correlationId,
            `R1F V2 E2E ${s.scenario_code}`,
            s.id
          ]);

          await pool.query(`
            select retail.r1f_generate_recommendations_v2(
              $1,$2,$3,$4,$5,true,$6
            )
          `,[
            s.intelligence_policy_id,
            s.window_end,
            run.runId,
            run.correlationId,
            `R1F V2 E2E ${s.scenario_code}`,
            s.id
          ]);
        }catch(e){
          errors.push({
            step:'build_or_recommend',
            error:String((e as Error).message??e)
          });
        }
      }

      const facts=await pool.query(`
        select id,r1d_job_id,fact_sha256,fact_document,
               collection_reconciliation_status,
               engine_version
        from retail.r1f_job_facts
        where certification_fixture=true
          and certification_batch_id=$1
          and engine_version='r1f-v2.0.0'
        order by r1d_job_id,id
      `,[s.id]);

      const observations=await pool.query(`
        select id,r1e_result_id,observation_sha256,
               observation_document,economic_amount,
               condition_normalized,fulfillment_mode,currency_code
        from retail.r1f_observation_facts
        where certification_fixture=true
          and certification_batch_id=$1
          and engine_version='r1f-v2.0.0'
        order by id
      `,[s.id]);

      const snapshots=await pool.query(`
        select id,location_fingerprint,opportunity_score,
               intelligence_sha256,intelligence_document,
               actual_cost_coverage_pct
        from retail.r1f_intelligence_snapshots
        where certification_fixture=true
          and certification_batch_id=$1
          and engine_version='r1f-v2.0.0'
        order by opportunity_score desc,id
      `,[s.id]);

      const recommendations=await pool.query(`
        select id,recommendation_type,compilation_id,
               recommended_child_compilation_ids,
               recommendation_sha256,recommendation_document
        from retail.r1f_search_recommendations
        where certification_fixture=true
          and certification_batch_id=$1
          and engine_version='r1f-v2.0.0'
        order by recommendation_priority,id
      `,[s.id]);

      // Database SHA is canonical jsonb text, so use SQL for authoritative check.
      const dbIntegrity=(await pool.query(`
        select
          (select count(*)=0
           from retail.r1f_job_facts
           where certification_batch_id=$1
             and engine_version='r1f-v2.0.0'
             and fact_sha256<>retail.r1f_sha256_jsonb(fact_document)
          ) facts_ok,
          (select count(*)=0
           from retail.r1f_observation_facts
           where certification_batch_id=$1
             and engine_version='r1f-v2.0.0'
             and observation_sha256<>
               retail.r1f_sha256_jsonb(observation_document)
          ) observations_ok,
          (select count(*)=0
           from retail.r1f_intelligence_snapshots
           where certification_batch_id=$1
             and engine_version='r1f-v2.0.0'
             and intelligence_sha256<>
               retail.r1f_sha256_jsonb(intelligence_document)
          ) snapshots_ok,
          (select count(*)=0
           from retail.r1f_search_recommendations
           where certification_batch_id=$1
             and engine_version='r1f-v2.0.0'
             and recommendation_sha256<>
               retail.r1f_sha256_jsonb(recommendation_document)
          ) recommendations_ok
      `,[s.id])).rows[0];

      const topLocation=snapshots.rows[0]?.location_fingerprint??null;
      const topOk=!s.expected_top_location_fingerprint
        ||topLocation===s.expected_top_location_fingerprint;

      const countsOk=
        facts.rowCount>=s.expected_minimum_facts
        &&snapshots.rowCount>=s.expected_minimum_snapshots
        &&recommendations.rowCount>=s.expected_minimum_recommendations;

      const reconcileOk=facts.rows.every(
        x=>x.collection_reconciliation_status==='MATCHED'
      );

      const ok=
        errors.length===0
        &&countsOk
        &&topOk
        &&reconcileOk
        &&dbIntegrity.facts_ok===true
        &&dbIntegrity.observations_ok===true
        &&dbIntegrity.snapshots_ok===true
        &&dbIntegrity.recommendations_ok===true;

      if(!ok) failed++;

      const chainManifest={
        facts:facts.rows.map(x=>({
          id:x.id,
          r1dJobId:x.r1d_job_id,
          factSha256:x.fact_sha256
        })),
        observations:observations.rows.map(x=>({
          id:x.id,
          r1eResultId:x.r1e_result_id,
          observationSha256:x.observation_sha256,
          economicAmount:x.economic_amount,
          condition:x.condition_normalized,
          fulfillment:x.fulfillment_mode,
          currency:x.currency_code
        })),
        snapshots:snapshots.rows.map(x=>({
          id:x.id,
          locationFingerprint:x.location_fingerprint,
          opportunityScore:x.opportunity_score,
          intelligenceSha256:x.intelligence_sha256
        })),
        recommendations:recommendations.rows.map(x=>({
          id:x.id,
          recommendationType:x.recommendation_type,
          compilationId:x.compilation_id,
          childCompilationIds:x.recommended_child_compilation_ids,
          recommendationSha256:x.recommendation_sha256
        }))
      };

      scenarioResults.push({
        scenarioCode:s.scenario_code,
        scenarioId:s.id,
        fixtureSha256:s.fixture_sha256,
        jobCount:s.job_ids.length,
        factCount:facts.rowCount,
        observationCount:observations.rowCount,
        snapshotCount:snapshots.rowCount,
        recommendationCount:recommendations.rowCount,
        expectedTopLocationFingerprint:s.expected_top_location_fingerprint,
        actualTopLocationFingerprint:topLocation,
        topOk,
        countsOk,
        reconcileOk,
        dbIntegrity,
        errors,
        chainManifest,
        ok
      });

      await finishPersistentRun(
        pool,run.runId,
        ok?'SUCCEEDED':'FAILED',
        {
          seen:s.job_ids.length,
          succeeded:ok?s.job_ids.length:0,
          failed:ok?0:s.job_ids.length
        },
        ok?undefined:new Error(`R1F E2E scenario ${s.scenario_code} failed`),
        {scenarioCode:s.scenario_code,ok,errors}
      );
    }catch(e){
      failed++;
      scenarioResults.push({
        scenarioCode:s.scenario_code,
        scenarioId:s.id,
        fixtureSha256:s.fixture_sha256,
        jobCount:s.job_ids.length,
        ok:false,
        error:String((e as Error).message??e)
      });
      await finishPersistentRun(
        pool,run.runId,'FAILED',
        {seen:s.job_ids.length,succeeded:0,failed:s.job_ids.length},
        e
      ).catch(()=>undefined);
    }
  }

  const allPassed=failed===0;

  console.log(JSON.stringify({
    allPassed,
    scenarioCount:scenarios.rowCount,
    totalJobs,
    failed,
    scenarios:scenarioResults
  },null,2));

  await pool.end();
  if(!allPassed) process.exitCode=2;
}

main().catch(e=>{console.error(e);process.exitCode=1;});
