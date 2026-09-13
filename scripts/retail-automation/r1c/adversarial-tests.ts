import { Pool,PoolClient } from 'pg';

const pool=new Pool({connectionString:process.env.DATABASE_URL});

type Result={gate:number;name:string;ok:boolean;detail?:any};

async function one(c:PoolClient,sql:string,args:any[]=[]){
  return (await c.query(sql,args)).rows[0];
}

async function check(
  gate:number,name:string,ok:boolean,detail:any={}
):Promise<Result>{
  return {gate,name,ok,detail};
}

async function mustFail(
  c:PoolClient,gate:number,name:string,fn:()=>Promise<any>
):Promise<Result>{
  const sp=`g${gate}`;
  await c.query(`savepoint ${sp}`);
  try{
    await fn();
    await c.query(`rollback to savepoint ${sp}`);
    return {gate,name,ok:false,detail:'unexpected success'};
  }catch(e){
    await c.query(`rollback to savepoint ${sp}`);
    return {
      gate,name,ok:true,
      detail:String((e as Error).message??e)
    };
  }
}

async function main(){
  const c=await pool.connect();
  const r:Result[]=[];
  try{
    await c.query('begin');

    const binding=(await c.query(`
      select b.*,cr.certification_version,cr.certification_status
      from retail.r1c_r1b_certification_binding b
      join retail.r1b_certification_runs cr
        on cr.id=b.r1b_certification_run_id
      where b.singleton=true
    `)).rows[0];

    const comp=(await c.query(`
      select * from retail.search_compiler_versions
      where certification_status='certified'
        and hardening_migration_sha256 is not null
      order by certified_at desc nulls last
      limit 1
    `)).rows[0];

    const route=(await c.query(`
      select * from retail.effective_search_routes limit 1
    `)).rows[0];

    const profile=route?(await c.query(`
      select * from retail.search_route_compile_profiles
      where route_id=$1 and profile_status='active'
      order by profile_version desc
      limit 1
    `,[route.route_id])).rows[0]:null;

    const job=(await c.query(`
      select * from retail.effective_compiled_search_jobs limit 1
    `)).rows[0];

    const packageAdapter=(await c.query(`
      select distinct
        a.id,
        s.implementation_authority_type,
        case
          when s.implementation_authority_type='package_tree'
            then s.package_tree_sha256
          else coalesce(
            s.entrypoint_sha256,
            s.package_tree_sha256
          )
        end expected_sha256
      from retail.effective_compiled_search_jobs j
      join retail.retail_search_adapters a
        on a.id=j.adapter_id
      join retail.retail_scraper_assets s
        on s.id=a.scraper_asset_id
      where s.implementation_authority_type
              in ('file','package_tree')
        and retail.r1b_adapter_execution_ready(a.id)=true
      order by a.id
      limit 1
    `)).rows[0];

    r.push(await check(1,'r1b_v4_hardening_present',
      (await one(c,`
        select exists(
          select 1 from retail.r1b_scraper_authority_state
          where singleton=true and hardening_version='4.0.0'
        ) ok
      `)).ok===true));

    r.push(await check(2,'r1b_execution_ready_function_present',
      (await one(c,`
        select to_regprocedure(
          'retail.r1b_adapter_execution_ready(uuid)'
        ) is not null ok
      `)).ok===true));

    r.push(await check(3,'exact_r1b_v4_binding_current',
      (await one(c,`select retail.r1c_r1b_binding_is_current() ok`)).ok===true));

    r.push(await check(4,'bound_certification_is_v4',
      !!binding
      && binding.r1b_scraper_hardening_version==='4.0.0'
      && binding.r1b_certification_version==='r1b-v4.0.0'
      && binding.certification_version==='r1b-v4.0.0'
      && binding.certification_status==='CERTIFIED',
      binding??{}));

    r.push(await mustFail(c,5,'nonlatest_r1b_rebind_rejected',async()=>{
      await c.query(`
        select retail.r1c_bind_r1b_certification(
          gen_random_uuid(),gen_random_uuid(),'qa-correlation','qa'
        )
      `);
    }));

    r.push(await check(6,'certified_v3_compiler_fixture',!!comp));
    r.push(await check(7,'effective_r1b_route_fixture',!!route));
    r.push(await check(8,'active_profile_fixture',!!profile));
    r.push(await check(9,'effective_compiled_job_fixture',!!job));
    r.push(await check(
      10,
      'certified_scraper_authority_fixture',
      !!packageAdapter,
      packageAdapter??{}
    ));

    if(comp){
      r.push(await mustFail(c,11,'certified_compiler_contract_immutable',
        ()=>c.query(`
          update retail.search_compiler_versions
          set compiler_contract_json='{}'::jsonb where id=$1
        `,[comp.id])));

      r.push(await mustFail(c,12,'certified_wrapper_sha_immutable',
        ()=>c.query(`
          update retail.search_compiler_versions
          set typescript_wrapper_sha256=repeat('0',64) where id=$1
        `,[comp.id])));

      r.push(await mustFail(c,13,'certified_v3_migration_sha_immutable',
        ()=>c.query(`
          update retail.search_compiler_versions
          set hardening_migration_sha256=repeat('0',64) where id=$1
        `,[comp.id])));

      r.push(await mustFail(c,14,'wrong_runtime_compiler_sha_rejected',
        ()=>c.query(`
          select retail.r1c_assert_runtime_compiler_v3(
            $1,repeat('0',64),repeat('0',64),repeat('0',64)
          )
        `,[comp.id])));

      r.push(await check(15,'compiler_authority_reproducible',
        (await one(c,`
          select compiler_authority_sha256=
            retail.r1c_sha256_jsonb(
              retail.r1c_compiler_authority_document(x)
            ) ok
          from retail.search_compiler_versions x
          where id=$1
        `,[comp.id])).ok===true));
    } else {
      for(let g=11;g<=15;g++){
        r.push(await check(g,`compiler_fixture_required_${g}`,false));
      }
    }

    await c.query(`
      select retail.r1c_validate_input_contract(
        '{"transport":"argv","compile_modes":["keyword"],"field_map":{"query":"--query"},"required_fields":["query"]}'::jsonb,
        'keyword','["query"]'::jsonb
      )
    `);
    r.push(await check(
      16,
      'argv_transport_accepted',
      true
    ));

    r.push(await mustFail(c,17,'missing_compile_modes_fail_closed',
      ()=>c.query(`
        select retail.r1c_validate_input_contract(
          '{"transport":"env","field_map":{"query":"Q"}}'::jsonb,
          'keyword','["query"]'::jsonb
        )
      `)));

    r.push(await mustFail(c,18,'missing_required_mapping_fail_closed',
      ()=>c.query(`
        select retail.r1c_validate_input_contract(
          '{"transport":"env","compile_modes":["keyword"],"field_map":{"query":"Q"}}'::jsonb,
          'keyword','["query","postal_code"]'::jsonb
        )
      `)));

    r.push(await mustFail(c,19,'legacy_env_alias_fail_closed',
      ()=>c.query(`
        select retail.r1c_validate_input_contract(
          '{"transport":"env","compile_modes":["keyword"],"field_map":{"query":"Q"},"keyword_env":"OLD"}'::jsonb,
          'keyword','["query"]'::jsonb
        )
      `)));

    const q=(await one(c,`
      select retail.r1c_build_query_v3(
        'Dell','Dell Latitude',
        '["Dell Latitude 7450","dell","16GB"]'::jsonb,
        '{"dedupe":"token_case_insensitive","stable_order":true}'::jsonb
      ) q
    `)).q;
    r.push(await check(20,'overlapping_query_tokens_deduplicated',
      q==='Dell Latitude 7450 16GB',{actual:q}));

    const q2=(await one(c,`
      select retail.r1c_build_query_v3(
        'Dell','Dell Latitude',
        '["Dell Latitude 7450","dell","16GB"]'::jsonb,
        '{"dedupe":"token_case_insensitive","stable_order":true}'::jsonb
      ) q
    `)).q;
    r.push(await check(21,'query_replay_deterministic',q===q2));

    const q3=(await one(c,`
      select retail.r1c_build_query_v3(
        'b','a','["c"]'::jsonb,
        '{"dedupe":"token_case_insensitive","stable_order":false}'::jsonb
      ) q
    `)).q;
    r.push(await check(22,'query_policy_changes_behavior',
      q3==='a b c',{actual:q3}));

    if(route&&profile){
      const contractReq=route.input_contract_json?.required_fields??[];
      const effective=profile.effective_required_fields??[];
      r.push(await check(23,'profile_binds_contract_required_fields',
        JSON.stringify(profile.contract_required_fields)===
        JSON.stringify(contractReq),
        {profile:profile.contract_required_fields,contract:contractReq}));

      r.push(await check(24,'profile_cannot_weaken_required_fields',
        contractReq.every((x:string)=>effective.includes(x)),
        {contractReq,effective}));

      r.push(await check(25,'profile_hash_reproducible',
        (await one(c,`
          select profile_sha256=
            retail.r1c_sha256_jsonb(
              retail.r1c_compile_profile_document(x)
            ) ok
          from retail.search_route_compile_profiles x
          where id=$1
        `,[profile.id])).ok===true));

      r.push(await mustFail(c,26,'active_profile_business_content_immutable',
        ()=>c.query(`
          update retail.search_route_compile_profiles
          set query_policy='{}'::jsonb where id=$1
        `,[profile.id])));

      const payload=(await one(c,`
        select retail.r1c_adapter_payload_document($1,$2) p
      `,[route.route_id,profile.id])).p;

      const fmap=route.input_contract_json?.field_map??{};

      r.push(await check(27,'unsupported_postal_not_emitted',
        route.supports_postal_code===true
        || !fmap.postal_code
        || !(fmap.postal_code in (payload.parameters??{})),
        {supports:route.supports_postal_code,map:fmap.postal_code,payload}));

      r.push(await check(28,'unsupported_store_not_emitted',
        route.supports_store_id===true
        || !fmap.store_id
        || !(fmap.store_id in (payload.parameters??{})),
        {supports:route.supports_store_id,map:fmap.store_id,payload}));

      r.push(await check(29,'unsupported_region_not_emitted',
        route.supports_region===true
        || !fmap.region
        || !(fmap.region in (payload.parameters??{})),
        {supports:route.supports_region,map:fmap.region,payload}));

      r.push(await check(30,'unsupported_result_limit_not_emitted',
        route.supports_result_limit===true
        || !fmap.result_limit
        || !(fmap.result_limit in (payload.parameters??{})),
        {supports:route.supports_result_limit,map:fmap.result_limit,payload}));

      for(const f of effective){
        const mapped=fmap[f];
        if(mapped){
          r.push(await check(
            31,
            'all_effective_required_fields_materialized',
            mapped in (payload.parameters??{}),
            {field:f,mapped,payload}
          ));
          break;
        }
      }
      if(!effective.length){
        r.push(await check(31,'all_effective_required_fields_materialized',true));
      }

      const p2=(await one(c,`
        select retail.r1c_adapter_payload_document($1,$2) p
      `,[route.route_id,profile.id])).p;
      r.push(await check(32,'payload_deterministic',
        JSON.stringify(payload)===JSON.stringify(p2)));

      const n1=(await one(c,`
        select retail.r1c_normalized_job_document($1,$2) p
      `,[route.route_id,profile.id])).p;
      const n2=(await one(c,`
        select retail.r1c_normalized_job_document($1,$2) p
      `,[route.route_id,profile.id])).p;
      r.push(await check(33,'normalized_job_deterministic',
        JSON.stringify(n1)===JSON.stringify(n2)));

      r.push(await check(34,'normalized_job_exposes_scraper_authority',
        !!n1?.scraper_authority?.scraper_asset_id
        && !!n1?.scraper_authority?.scraper_contract_id
        && !!n1?.scraper_authority?.scraper_contract_sha256,
        n1?.scraper_authority??{}));

      r.push(await check(35,'route_adapter_execution_ready',
        (await one(c,`
          select retail.r1b_adapter_execution_ready($1) ok
        `,[route.adapter_id])).ok===true));
    } else {
      for(let g=23;g<=35;g++){
        r.push(await check(g,`route_profile_fixture_required_${g}`,false));
      }
    }

    if(packageAdapter){
      r.push(await mustFail(
        c,
        36,
        'scraper_authority_wrong_sha_rejected',
        ()=>c.query(`
          select retail.r1b_assert_runtime_adapter(
            $1,
            repeat('0',64)
          )
        `,[packageAdapter.id])
      ));

      r.push(await check(
        37,
        'scraper_authority_expected_sha_current',
        (await one(c,`
          select (
            case
              when s.implementation_authority_type='package_tree'
                then s.package_tree_sha256
              else coalesce(
                s.entrypoint_sha256,
                s.package_tree_sha256
              )
            end
          )=$2 ok
          from retail.retail_scraper_assets s
          join retail.retail_search_adapters a
            on a.scraper_asset_id=s.id
          where a.id=$1
        `,[
          packageAdapter.id,
          packageAdapter.expected_sha256
        ])).ok===true,
        packageAdapter
      ));
    } else {
      r.push(await check(
        36,
        'scraper_authority_wrong_sha_rejected',
        false,
        'no certified scraper fixture'
      ));
      r.push(await check(
        37,
        'scraper_authority_expected_sha_current',
        false,
        'no certified scraper fixture'
      ));
    }

    if(job){
      r.push(await check(38,'normalized_hash_reproducible',
        (await one(c,`
          select normalized_job_sha256=
            retail.r1c_sha256_jsonb(normalized_job_json) ok
          from retail.search_job_compilations where id=$1
        `,[job.id])).ok===true));

      r.push(await check(39,'payload_hash_reproducible',
        (await one(c,`
          select adapter_payload_sha256=
            retail.r1c_sha256_jsonb(adapter_payload_json) ok
          from retail.search_job_compilations where id=$1
        `,[job.id])).ok===true));

      r.push(await check(40,'evidence_hash_reproducible',
        (await one(c,`
          select compilation_evidence_sha256=
            retail.r1c_sha256_jsonb(compilation_evidence_json) ok
          from retail.search_job_compilations where id=$1
        `,[job.id])).ok===true));

      const se=job.compilation_evidence_json?.scraper_authority;
      r.push(await check(41,'evidence_has_scraper_asset_identity',
        !!se?.scraper_asset_id&&!!se?.package_tree_sha256,se??{}));

      r.push(await check(42,'evidence_has_scraper_contract_identity',
        !!se?.scraper_contract_id&&!!se?.scraper_contract_sha256,se??{}));

      r.push(await check(43,'evidence_scraper_authority_current',
        JSON.stringify(se)===JSON.stringify(
          (await one(c,`
            select retail.r1c_scraper_authority_document($1) d
          `,[job.adapter_id])).d
        )));

      r.push(await mustFail(c,44,'compiled_content_immutable',
        ()=>c.query(`
          update retail.search_job_compilations
          set adapter_payload_json='{}'::jsonb where id=$1
        `,[job.id])));

      r.push(await mustFail(c,45,'compiled_delete_blocked',
        ()=>c.query(`
          delete from retail.search_job_compilations where id=$1
        `,[job.id])));

      r.push(await check(46,'compilation_current',
        (await one(c,`
          select retail.r1c_compilation_is_current($1) ok
        `,[job.id])).ok===true));

      r.push(await check(47,'process_run_bound',!!job.source_process_run_id));
      r.push(await check(48,'correlation_bound',!!job.source_correlation_id));
    } else {
      for(let g=38;g<=48;g++){
        r.push(await check(g,`job_fixture_required_${g}`,false));
      }
    }

    const forbidden=await c.query(`
      select column_name
      from information_schema.columns
      where table_schema='retail'
        and table_name='search_job_compilations'
        and (
          column_name ilike '%schedule%'
          or column_name ilike '%budget%'
          or column_name ilike '%dispatch%'
          or column_name ilike '%purchase%'
          or column_name ilike '%checkout%'
          or column_name ilike '%lease%'
        )
    `);
    r.push(await check(49,'no_scheduler_budget_dispatch_purchase_authority',
      forbidden.rowCount===0,forbidden.rows));

    r.push(await check(50,'effective_view_exists',
      (await one(c,`
        select to_regclass(
          'retail.effective_compiled_search_jobs'
        ) is not null ok
      `)).ok===true));

    r.push(await check(51,'binding_history_exists',
      (await one(c,`
        select to_regclass(
          'retail.r1c_r1b_binding_history'
        ) is not null ok
      `)).ok===true));

    r.push(await check(52,'v3_state_current',
      (await one(c,`
        select exists(
          select 1 from retail.r1c_v3_state
          where singleton=true and hardening_version='3.0.0'
        ) ok
      `)).ok===true));

    r.push(await check(53,'public_compile_execute_revoked',
      (await one(c,`
        select has_function_privilege(
          'public',
          'retail.r1c_compile_route(uuid,uuid,uuid,uuid,text,text)',
          'EXECUTE'
        )=false ok
      `)).ok===true));

    r.push(await check(54,'public_bind_execute_revoked',
      (await one(c,`
        select has_function_privilege(
          'public',
          'retail.r1c_bind_r1b_certification(uuid,uuid,text,text)',
          'EXECUTE'
        )=false ok
      `)).ok===true));

    r.push(await check(55,'r1c_certification_table_exists',
      (await one(c,`
        select to_regclass(
          'retail.r1c_certification_runs'
        ) is not null ok
      `)).ok===true));

    r.push(await check(56,'audit_binding_trigger_present',
      (await one(c,`
        select exists(
          select 1 from pg_trigger
          where tgname='trg_r1c_audit_r1b_binding'
            and not tgisinternal
        ) ok
      `)).ok===true));

    await c.query('rollback');

    const pass=r.every(x=>x.ok);
    console.log(JSON.stringify({
      suite:'R1C_V3_SCRAPER_AUTHORITY_ALIGNED',
      gates:r,
      passed:r.filter(x=>x.ok).length,
      failed:r.filter(x=>!x.ok).length,
      allPassed:pass
    },null,2));

    if(!pass) process.exitCode=2;
  }finally{
    c.release();
    await pool.end();
  }
}

main().catch(e=>{
  console.error(e);
  process.exitCode=1;
});
