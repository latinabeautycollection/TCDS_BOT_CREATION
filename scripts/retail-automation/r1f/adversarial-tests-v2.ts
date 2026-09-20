import { Pool,PoolClient } from 'pg';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [policyId]=process.argv.slice(2);

if(!policyId){
  throw new Error('usage: tsx adversarial-tests-v2.ts <intelligence_policy_uuid>');
}

async function mustFail(
  c:PoolClient,
  name:string,
  fn:()=>Promise<any>
){
  const sp='sp_'+name.replace(/[^a-z0-9]/gi,'_').slice(0,40);
  await c.query(`savepoint ${sp}`);
  try{
    await fn();
    await c.query(`rollback to savepoint ${sp}`);
    return {name,ok:false,detail:'unexpected success'};
  }catch(e){
    await c.query(`rollback to savepoint ${sp}`);
    return {
      name,ok:true,
      detail:String((e as Error).message??e)
    };
  }
}

async function main(){
  const c=await pool.connect();
  const g:any[]=[];
  const one=async(sql:string,args:any[]=[])=>(await c.query(sql,args)).rows[0];
  const gate=(name:string,ok:boolean,detail:any={})=>g.push({name,ok,detail});

  try{
    await c.query('begin');

    gate('v2_state',
      (await one(`
        select exists(
          select 1 from retail.r1f_v2_state
          where singleton and hardening_version='2.0.0'
        ) ok
      `)).ok);

    gate('r1e_binding_current',
      (await one(`select retail.r1f_r1e_binding_is_current() ok`)).ok);

    gate('legacy_ingest_revoked',
      (await one(`
        select not has_function_privilege(
          'retail_r1f_worker',
          'retail.r1f_ingest_completed_job(uuid,uuid,text,text)',
          'EXECUTE'
        ) ok
      `)).ok);

    gate('legacy_build_revoked',
      (await one(`
        select not has_function_privilege(
          'retail_r1f_worker',
          'retail.r1f_build_intelligence(uuid,timestamptz,uuid,text,text)',
          'EXECUTE'
        ) ok
      `)).ok);

    gate('legacy_recommend_revoked',
      (await one(`
        select not has_function_privilege(
          'retail_r1f_worker',
          'retail.r1f_generate_recommendations(uuid,timestamptz,uuid,text,text)',
          'EXECUTE'
        ) ok
      `)).ok);

    gate('v2_runtime_granted',
      (await one(`
        select has_function_privilege(
          'retail_r1f_worker',
          'retail.r1f_ingest_completed_job_v2(uuid,uuid,text,text,boolean,uuid)',
          'EXECUTE'
        ) ok
      `)).ok);

    const econ=(await one(`
      select retail.r1f_economic_amount_document(
        '{
          "offer":{
            "currency_code":"USD",
            "effective_price":599,
            "shipping_cost_estimate":80,
            "estimated_tax":46,
            "estimated_total_cost":725
          }
        }'::jsonb
      ) d
    `)).d;

    gate(
      'landed_cost_prefers_estimated_total',
      Number(econ.economic_amount)===725
      &&econ.price_basis==='ESTIMATED_TOTAL_COST',
      econ
    );

    const econFallback=(await one(`
      select retail.r1f_economic_amount_document(
        '{
          "offer":{
            "currency_code":"USD",
            "effective_price":635,
            "shipping_cost_estimate":0,
            "estimated_tax":45
          }
        }'::jsonb
      ) d
    `)).d;

    gate(
      'landed_cost_fallback_adds_known_costs',
      Number(econFallback.economic_amount)===680,
      econFallback
    );

    gate('non_usd_rejected',
      (await one(`
        select (
          retail.r1f_economic_amount_document(
            '{"offer":{"currency_code":"EUR","effective_price":500}}'::jsonb
          )->>'supported'
        )::boolean=false ok
      `)).ok);

    gate('condition_normalization',
      (await one(`
        select retail.r1f_normalize_condition('Open Box Excellent')='OPEN_BOX' ok
      `)).ok);

    gate('policy_current',
      (await one(`
        select exists(
          select 1 from retail.r1f_intelligence_policies
          where id=$1
            and certification_status='certified'
            and policy_sha256=retail.r1f_sha256_jsonb(policy_json)
        ) ok
      `,[policyId])).ok);

    const policy=(await c.query(`
      select policy_json
      from retail.r1f_intelligence_policies
      where id=$1
    `,[policyId])).rows[0]?.policy_json;

    if(policy){
      g.push(await mustFail(c,'negative_weight_rejected',()=>c.query(`
        select retail.r1f_validate_policy(
          jsonb_set(
            jsonb_set($1::jsonb,'{score_weights,qualification_yield}','-2'::jsonb),
            '{score_weights,relative_bargain}','3'::jsonb
          )
        )
      `,[JSON.stringify(policy)])));

      g.push(await mustFail(c,'future_window_rejected',()=>c.query(`
        select retail.r1f_assert_window_end(
          clock_timestamp()+interval '10 days',
          $1::jsonb
        )
      `,[JSON.stringify(policy)])));

      const score=(await one(`
        select retail.r1f_score_document_v2(
          '{
            "total_observations":100,
            "qualified_observations":80,
            "cost_per_qualified_usd":0.02,
            "relative_bargain_pct":0.30,
            "available_qualified":75,
            "freshness_age_days":0.2,
            "actual_cost_coverage_pct":1
          }'::jsonb,
          $1::jsonb
        ) s
      `,[JSON.stringify(policy)])).s;

      const scoreLowCoverage=(await one(`
        select retail.r1f_score_document_v2(
          '{
            "total_observations":100,
            "qualified_observations":80,
            "cost_per_qualified_usd":0.02,
            "relative_bargain_pct":0.30,
            "available_qualified":75,
            "freshness_age_days":0.2,
            "actual_cost_coverage_pct":0
          }'::jsonb,
          $1::jsonb
        ) s
      `,[JSON.stringify(policy)])).s;

      gate(
        'estimated_cost_coverage_reduces_cost_score',
        Number(score.cost_efficiency_score)>
        Number(scoreLowCoverage.cost_efficiency_score),
        {full:score,lowCoverage:scoreLowCoverage}
      );

      const ranked=(await one(`
        select retail.r1f_rank_locations(
          '[
            {"location_code":"VA","metrics":{
              "total_observations":100,"qualified_observations":80,
              "cost_per_qualified_usd":0.03,"relative_bargain_pct":0.05,
              "available_qualified":75,"freshness_age_days":1,
              "actual_cost_coverage_pct":1}},
            {"location_code":"GA","metrics":{
              "total_observations":100,"qualified_observations":80,
              "cost_per_qualified_usd":0.03,"relative_bargain_pct":0.30,
              "available_qualified":75,"freshness_age_days":1,
              "actual_cost_coverage_pct":1}}
          ]'::jsonb,
          $1::jsonb
        ) r
      `,[JSON.stringify(policy)])).r;

      gate(
        'stronger_national_bargain_ranks_first',
        ranked[0].location_code==='GA',
        ranked
      );
    }else{
      gate('negative_weight_rejected',false,'policy missing');
      gate('future_window_rejected',false,'policy missing');
      gate('estimated_cost_coverage_reduces_cost_score',false,'policy missing');
      gate('stronger_national_bargain_ranks_first',false,'policy missing');
    }

    const certPolicy=(await c.query(`
      select id
      from retail.r1f_certification_policies
      where certification_status='certified'
      order by certified_at desc,id::text desc
      limit 1
    `)).rows[0];

    if(certPolicy){
      await c.query(`
        update retail.r1f_certification_policies
        set certification_status='suspended'
        where id=$1
      `,[certPolicy.id]);

      g.push(await mustFail(
        c,'suspended_cert_policy_cannot_reactivate',
        ()=>c.query(`
          update retail.r1f_certification_policies
          set certification_status='certified'
          where id=$1
        `,[certPolicy.id])
      ));
    }else{
      gate('suspended_cert_policy_cannot_reactivate',false,'cert policy missing');
    }

    gate('e2e_scenarios_present',
      (await one(`
        select count(*)>0 ok
        from retail.r1f_e2e_qa_scenarios
        where active=true and scenario_type='E2E'
      `)).ok);

    gate('concurrency_scenario_present',
      (await one(`
        select count(*)>0 ok
        from retail.r1f_e2e_qa_scenarios
        where active=true and scenario_type='CONCURRENCY'
      `)).ok);

    gate('condition_fulfillment_baseline_exact',
      (await one(`
        select pg_get_functiondef(
          'retail.r1f_build_intelligence_v2(uuid,timestamptz,uuid,text,text,boolean,uuid)'::regprocedure
        ) like '%o2.condition_normalized=o.condition_normalized%'
        and pg_get_functiondef(
          'retail.r1f_build_intelligence_v2(uuid,timestamptz,uuid,text,text,boolean,uuid)'::regprocedure
        ) like '%o2.fulfillment_mode=o.fulfillment_mode%' ok
      `)).ok);

    gate('cross_retailer_baseline',
      (await one(`
        select pg_get_functiondef(
          'retail.r1f_build_intelligence_v2(uuid,timestamptz,uuid,text,text,boolean,uuid)'::regprocedure
        ) not like '%o2.platform_id=o.platform_id%'
        and pg_get_functiondef(
          'retail.r1f_build_intelligence_v2(uuid,timestamptz,uuid,text,text,boolean,uuid)'::regprocedure
        ) like '%o2.r1a_revision_hash=o.r1a_revision_hash%' ok
      `)).ok);

    gate('exact_child_compilation_resolver',
      (await one(`
        select to_regprocedure(
          'retail.r1f_authorized_child_compilations(uuid,uuid,timestamptz,integer)'
        ) is not null ok
      `)).ok);

    gate('local_time_intelligence',
      (await one(`
        select to_regclass(
          'retail.r1f_local_temporal_search_intelligence'
        ) is not null ok
      `)).ok);

    gate('full_pipeline_certification_required',
      (await one(`
        select pg_get_functiondef(
          'retail.r1f_latest_certification_is_current()'::regprocedure
        ) like '%e2e_results%'
        and pg_get_functiondef(
          'retail.r1f_latest_certification_is_current()'::regprocedure
        ) like '%concurrency_results%' ok
      `)).ok);

    gate('r1e_identity_mismatch_invalidates',
      (await one(`
        select retail.r1f_r1e_identity_is_current(
          gen_random_uuid(),repeat('0',64)
        )=false ok
      `)).ok);

    const bindingRow=(await c.query(`
      select * from retail.r1f_r1e_certification_binding
      where singleton=true
    `)).rows[0];

    if(bindingRow){
      await c.query(`savepoint r1e_rebind_test`);
      await c.query(`
        update retail.r1f_r1e_certification_binding
        set r1e_package_sha256=repeat('0',64)
        where singleton=true
      `);
      gate(
        'active_r1e_rebind_invalidates_binding',
        (await one(`
          select retail.r1f_r1e_binding_is_current()=false ok
        `)).ok
      );
      await c.query(`rollback to savepoint r1e_rebind_test`);
    }else{
      gate('active_r1e_rebind_invalidates_binding',false,'binding missing');
    }

    gate('r1c_identity_mismatch_invalidates',
      (await one(`
        select retail.r1f_compilation_identity_is_current(
          gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
          repeat('0',64),gen_random_uuid(),repeat('0',64)
        )=false ok
      `)).ok);

    gate('certification_fixture_excluded_downstream',
      (await one(`
        select pg_get_viewdef(
          'retail.r1f_effective_search_recommendations'::regclass,true
        ) like '%certification_fixture = false%' ok
      `)).ok);

    gate('no_direct_r1d_mutation',
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
      `)).ok);

    gate('no_buy_profit_capital_authority',
      (await one(`
        select count(*)=0 ok
        from information_schema.columns
        where table_schema='retail'
          and table_name like 'r1f_%'
          and (
            column_name ilike '%net_profit%'
            or column_name ilike '%roi%'
            or column_name ilike '%purchase_authorization%'
            or column_name ilike '%checkout_authorization%'
            or column_name ilike '%capital_allocation%'
          )
      `)).ok);

    await c.query('rollback');

    const pass=g.every(x=>x.ok);

    console.log(JSON.stringify({
      suite:'R1F_V2_GREEN_TIER1_FINAL',
      allPassed:pass,
      passed:g.filter(x=>x.ok).length,
      failed:g.filter(x=>!x.ok).length,
      gates:g
    },null,2));

    if(!pass) process.exitCode=2;
  }finally{
    c.release();
    await pool.end();
  }
}

main().catch(e=>{console.error(e);process.exitCode=1;});
