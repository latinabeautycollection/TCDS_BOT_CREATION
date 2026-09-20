import { Pool } from 'pg';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [policyId]=process.argv.slice(2);

if(!policyId){
  throw new Error('usage: tsx adversarial-tests.ts <intelligence_policy_uuid>');
}

async function main(){
  const g:any[]=[];
  const gate=(name:string,ok:boolean,detail:any={})=>
    g.push({name,ok,detail});

  const one=async(sql:string,args:any[]=[])=>
    (await pool.query(sql,args)).rows[0];

  gate(
    'schema_current',
    (await one(`
      select exists(
        select 1 from retail.r1f_schema_state
        where singleton and schema_version='1.0.0'
      ) ok
    `)).ok
  );

  gate(
    'r1e_binding_current',
    (await one(`
      select retail.r1f_r1e_binding_is_current() ok
    `)).ok
  );

  gate(
    'intelligence_policy_current',
    (await one(`
      select exists(
        select 1
        from retail.r1f_intelligence_policies
        where id=$1
          and certification_status='certified'
          and policy_sha256=retail.r1f_sha256_jsonb(policy_json)
      ) ok
    `,[policyId])).ok
  );

  gate(
    'certification_policy_current',
    (await one(`
      select count(*)=1 ok
      from retail.r1f_certification_policies
      where certification_status='certified'
        and policy_sha256=retail.r1f_sha256_jsonb(policy_json)
    `)).ok
  );

  gate(
    'job_fact_immutability_trigger',
    (await one(`
      select exists(
        select 1 from pg_trigger
        where tgname='trg_r1f_fact_guard'
          and not tgisinternal
      ) ok
    `)).ok
  );

  gate(
    'observation_fact_immutability_trigger',
    (await one(`
      select exists(
        select 1 from pg_trigger
        where tgname='trg_r1f_observation_guard'
          and not tgisinternal
      ) ok
    `)).ok
  );

  gate(
    'snapshot_immutability_trigger',
    (await one(`
      select exists(
        select 1 from pg_trigger
        where tgname='trg_r1f_snapshot_guard'
          and not tgisinternal
      ) ok
    `)).ok
  );

  gate(
    'recommendation_guard_present',
    (await one(`
      select exists(
        select 1 from pg_trigger
        where tgname='trg_r1f_recommendation_guard'
          and not tgisinternal
      ) ok
    `)).ok
  );

  gate(
    'certification_append_only',
    (await one(`
      select exists(
        select 1 from pg_trigger
        where tgname='trg_r1f_certification_guard'
          and not tgisinternal
      ) ok
    `)).ok
  );

  gate(
    'binding_history_append_only',
    (await one(`
      select exists(
        select 1 from pg_trigger
        where tgname='trg_r1f_binding_history_guard'
          and not tgisinternal
      ) ok
    `)).ok
  );

  gate(
    'job_fact_hashes_reproduce',
    (await one(`
      select count(*)=0 ok
      from retail.r1f_job_facts
      where fact_sha256<>retail.r1f_sha256_jsonb(fact_document)
    `)).ok
  );

  gate(
    'observation_hashes_reproduce',
    (await one(`
      select count(*)=0 ok
      from retail.r1f_observation_facts
      where observation_sha256<>
        retail.r1f_sha256_jsonb(observation_document)
    `)).ok
  );

  gate(
    'snapshot_hashes_reproduce',
    (await one(`
      select count(*)=0 ok
      from retail.r1f_intelligence_snapshots
      where intelligence_sha256<>
        retail.r1f_sha256_jsonb(intelligence_document)
    `)).ok
  );

  gate(
    'recommendation_hashes_reproduce',
    (await one(`
      select count(*)=0 ok
      from retail.r1f_search_recommendations
      where recommendation_sha256<>
        retail.r1f_sha256_jsonb(recommendation_document)
    `)).ok
  );

  gate(
    'facts_current_r1e_only',
    (await one(`
      select count(*)=0 ok
      from retail.r1f_job_facts f
      left join retail.r1f_r1e_certification_binding b
        on b.singleton=true
       and b.r1e_certification_run_id=f.r1e_certification_run_id
      where b.singleton is null
    `)).ok
  );

  gate(
    'observation_revision_matches_job',
    (await one(`
      select count(*)=0 ok
      from retail.r1f_observation_facts o
      join retail.r1f_job_facts f on f.id=o.r1f_job_fact_id
      where o.r1a_revision_id<>f.r1a_revision_id
         or o.r1a_revision_hash<>f.r1a_revision_hash
    `)).ok
  );

  gate(
    'no_duplicate_job_fact_for_current_cert',
    (await one(`
      select count(*)=0 ok
      from (
        select r1d_job_id,r1e_certification_run_id,count(*)
        from retail.r1f_job_facts
        group by 1,2
        having count(*)>1
      ) x
    `)).ok
  );

  gate(
    'no_duplicate_r1e_observation_fact',
    (await one(`
      select count(*)=0 ok
      from (
        select r1e_result_id,count(*)
        from retail.r1f_observation_facts
        group by 1
        having count(*)>1
      ) x
    `)).ok
  );

  gate(
    'wilson_zero_safe',
    Number((await one(`
      select retail.r1f_wilson_lower_bound(0,0) v
    `)).v)===0
  );

  const w1=Number((await one(`
    select retail.r1f_wilson_lower_bound(80,100) v
  `)).v);
  const w2=Number((await one(`
    select retail.r1f_wilson_lower_bound(8,10) v
  `)).v);

  gate(
    'wilson_penalizes_small_samples',
    w1>w2,
    {largeSample:w1,smallSample:w2}
  );

  const policy=(await pool.query(`
    select policy_json
    from retail.r1f_intelligence_policies
    where id=$1
  `,[policyId])).rows[0]?.policy_json;

  if(policy){
    const metrics={
      total_observations:100,
      qualified_observations:80,
      cost_per_qualified_usd:0.02,
      relative_bargain_pct:0.30,
      available_qualified:75,
      freshness_age_days:0.2
    };
    const a=(await one(`
      select retail.r1f_score_document(
        $1::jsonb,$2::jsonb
      ) score
    `,[JSON.stringify(metrics),JSON.stringify(policy)])).score;
    const b=(await one(`
      select retail.r1f_score_document(
        $1::jsonb,$2::jsonb
      ) score
    `,[JSON.stringify(metrics),JSON.stringify(policy)])).score;

    gate(
      'scoring_deterministic',
      JSON.stringify(a)===JSON.stringify(b),
      {first:a,second:b}
    );

    const rec=(await one(`
      select retail.r1f_recommendation_decision(
        $1::jsonb,$2::jsonb
      ) decision
    `,[
      JSON.stringify({
        opportunity_score:a.opportunity_score,
        sample_sufficiency:'SUFFICIENT',
        location:{location_type:'store'}
      }),
      JSON.stringify(policy)
    ])).decision;

    gate(
      'high_store_opportunity_increases_frequency',
      rec.recommendation_type==='INCREASE_FREQUENCY',
      rec
    );

    const explore=(await one(`
      select retail.r1f_recommendation_decision(
        $1::jsonb,$2::jsonb
      ) decision
    `,[
      JSON.stringify({
        opportunity_score:100,
        sample_sufficiency:'INSUFFICIENT',
        location:{location_type:'postal_code'}
      }),
      JSON.stringify(policy)
    ])).decision;

    gate(
      'insufficient_sample_forces_exploration',
      explore.recommendation_type==='EXPLORATION_SAMPLE',
      explore
    );
  }else{
    gate('scoring_deterministic',false,'policy missing');
    gate('high_store_opportunity_increases_frequency',false,'policy missing');
    gate('insufficient_sample_forces_exploration',false,'policy missing');
  }

  gate(
    'national_bargain_reference_cross_retailer',
    (await one(`
      select pg_get_functiondef(
        'retail.r1f_build_intelligence(uuid,timestamptz,uuid,text,text)'::regprocedure
      ) like '%o2.r1a_revision_hash=o.r1a_revision_hash%'
      and pg_get_functiondef(
        'retail.r1f_build_intelligence(uuid,timestamptz,uuid,text,text)'::regprocedure
      ) not like '%o2.platform_id=o.platform_id%' ok
    `)).ok
  );

  gate(
    'recommendations_require_current_compilation',
    (await one(`
      select pg_get_functiondef(
        'retail.r1f_generate_recommendations(uuid,timestamptz,uuid,text,text)'::regprocedure
      ) like '%effective_compiled_search_jobs%' ok
    `)).ok
  );

  gate(
    'effective_recommendations_require_r1f_certification',
    (await one(`
      select pg_get_viewdef(
        'retail.r1f_effective_search_recommendations'::regclass,true
      ) like '%r1f_latest_certification_is_current%' ok
    `)).ok
  );

  gate(
    'temporal_intelligence_exists',
    (await one(`
      select to_regclass(
        'retail.r1f_temporal_search_intelligence'
      ) is not null ok
    `)).ok
  );

  gate(
    'no_direct_r1d_mutation_functions',
    (await one(`
      select count(*)=0 ok
      from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='retail'
        and p.proname like 'r1f_%'
        and (
          lower(pg_get_functiondef(p.oid)) like '%update retail.r1d_%'
          or lower(pg_get_functiondef(p.oid)) like '%insert into retail.r1d_%'
          or lower(pg_get_functiondef(p.oid)) like '%delete from retail.r1d_%'
        )
    `)).ok
  );

  gate(
    'no_buy_profit_capital_authority',
    (await one(`
      select count(*)=0 ok
      from information_schema.columns
      where table_schema='retail'
        and table_name like 'r1f_%'
        and (
          column_name ilike '%profit%'
          or column_name ilike '%roi%'
          or column_name ilike '%margin%'
          or column_name ilike '%purchase_authorization%'
          or column_name ilike '%checkout_authorization%'
          or column_name ilike '%capital_allocation%'
          or column_name ilike '%buy_decision%'
        )
    `)).ok
  );

  gate(
    'public_ingest_revoked',
    (await one(`
      select not has_function_privilege(
        'public',
        'retail.r1f_ingest_completed_job(uuid,uuid,text,text)',
        'EXECUTE'
      ) ok
    `)).ok
  );

  gate(
    'public_intelligence_build_revoked',
    (await one(`
      select not has_function_privilege(
        'public',
        'retail.r1f_build_intelligence(uuid,timestamptz,uuid,text,text)',
        'EXECUTE'
      ) ok
    `)).ok
  );

  gate(
    'public_recommend_revoked',
    (await one(`
      select not has_function_privilege(
        'public',
        'retail.r1f_generate_recommendations(uuid,timestamptz,uuid,text,text)',
        'EXECUTE'
      ) ok
    `)).ok
  );

  gate(
    'r1e_rebind_invalidates_r1f_currentness',
    (await one(`
      select pg_get_functiondef(
        'retail.r1f_latest_certification_is_current()'::regprocedure
      ) like '%cr.r1e_certification_run_id=b.r1e_certification_run_id%'
      and pg_get_functiondef(
        'retail.r1f_latest_certification_is_current()'::regprocedure
      ) like '%cr.r1e_package_sha256=b.r1e_package_sha256%' ok
    `)).ok
  );

  const pass=g.every(x=>x.ok);

  console.log(JSON.stringify({
    suite:'R1F_V1_GREEN_TIER1',
    allPassed:pass,
    passed:g.filter(x=>x.ok).length,
    failed:g.filter(x=>!x.ok).length,
    gates:g
  },null,2));

  await pool.end();
  if(!pass) process.exitCode=2;
}

main().catch(e=>{
  console.error(e);
  process.exitCode=1;
});
