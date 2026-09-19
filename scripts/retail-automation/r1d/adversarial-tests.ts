import { Pool,PoolClient } from 'pg';

const pool=new Pool({connectionString:process.env.DATABASE_URL});

type Gate={gate:number;name:string;ok:boolean;detail?:any};

async function one(c:PoolClient,sql:string,args:any[]=[]){
  return (await c.query(sql,args)).rows[0];
}
async function check(gate:number,name:string,ok:boolean,detail:any={}):Promise<Gate>{
  return {gate,name,ok,detail};
}
async function mustFail(
  c:PoolClient,gate:number,name:string,fn:()=>Promise<any>
):Promise<Gate>{
  const sp=`g${gate}`;
  await c.query(`savepoint ${sp}`);
  try{
    await fn();
    await c.query(`rollback to savepoint ${sp}`);
    return {gate,name,ok:false,detail:'unexpected success'};
  }catch(e){
    await c.query(`rollback to savepoint ${sp}`);
    return {gate,name,ok:true,detail:String((e as Error).message??e)};
  }
}

async function main(){
  const c=await pool.connect();
  const g:Gate[]=[];

  try{
    await c.query('begin');

    const effective=(await c.query(`
      select * from retail.effective_compiled_search_jobs limit 1
    `)).rows[0];
    const binding=(await c.query(`
      select * from retail.r1d_dispatch_bindings
      where retail.r1d_dispatch_binding_is_current(id)=true
      limit 1
    `)).rows[0];
    const schedule=(await c.query(`
      select * from retail.r1d_schedule_policies
      where active=true limit 1
    `)).rows[0];
    const cost=(await c.query(`
      select * from retail.r1d_cost_profiles
      where active=true limit 1
    `)).rows[0];
    const job=(await c.query(`
      select * from retail.r1d_dispatch_jobs limit 1
    `)).rows[0];

    g.push(await check(1,'r1d_schema_version',
      (await one(c,`
        select exists(
          select 1 from retail.r1d_schema_state
          where singleton=true and schema_version='1.0.0'
        ) ok
      `)).ok===true));

    g.push(await check(2,'r1c_v3_binding_current',
      (await one(c,`select retail.r1d_r1c_binding_is_current() ok`)).ok===true));

    g.push(await check(3,'latest_r1c_certification_v3',
      (await one(c,`
        select exists(
          select 1 from retail.r1c_certification_runs
          where id=(
            select id from retail.r1c_certification_runs
            where completed_at is not null
            order by completed_at desc,id::text desc limit 1
          )
          and certification_version='r1c-v3.0.0'
          and certification_status='CERTIFIED'
        ) ok
      `)).ok===true));

    g.push(await check(4,'effective_compiled_job_fixture',!!effective));
    g.push(await check(5,'current_dispatch_binding_fixture',!!binding));
    g.push(await check(6,'active_schedule_policy_fixture',!!schedule));
    g.push(await check(7,'active_cost_profile_fixture',!!cost));

    g.push(await check(8,'active_global_budget_policy',
      (await one(c,`
        select exists(
          select 1 from retail.r1d_budget_policies
          where active and scope_type='GLOBAL'
        ) ok
      `)).ok===true));

    g.push(await check(9,'dispatch_binding_hashes_reproducible',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_dispatch_bindings b
        where b.certification_status='certified'
          and (
            b.binding_sha256<>
              retail.r1d_sha256_jsonb(
                retail.r1d_dispatch_binding_document(b)
              )
            or b.certification_evidence_sha256<>
              retail.r1d_sha256_jsonb(
                b.certification_evidence_json
              )
          )
      `)).ok===true));

    g.push(await check(10,'all_certified_bindings_current',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_dispatch_bindings
        where certification_status='certified'
          and retail.r1d_dispatch_binding_is_current(id) is not true
      `)).ok===true));

    if(binding){
      g.push(await mustFail(c,11,'certified_binding_business_content_immutable',
        ()=>c.query(`
          update retail.r1d_dispatch_bindings
          set timeout_seconds=timeout_seconds+1 where id=$1
        `,[binding.id])));

      g.push(await mustFail(c,12,'certified_binding_delete_blocked',
        ()=>c.query(`
          delete from retail.r1d_dispatch_bindings where id=$1
        `,[binding.id])));
    }else{
      g.push(await check(11,'certified_binding_business_content_immutable',false,'no fixture'));
      g.push(await check(12,'certified_binding_delete_blocked',false,'no fixture'));
    }

    if(job){
      g.push(await mustFail(c,13,'dispatch_authority_content_immutable',
        ()=>c.query(`
          update retail.r1d_dispatch_jobs
          set route_authority_hash=repeat('0',64)
          where id=$1
        `,[job.id])));

      g.push(await mustFail(c,14,'dispatch_job_delete_blocked',
        ()=>c.query(`
          delete from retail.r1d_dispatch_jobs where id=$1
        `,[job.id])));
    }else{
      g.push(await check(13,'dispatch_authority_content_immutable',false,'no job fixture'));
      g.push(await check(14,'dispatch_job_delete_blocked',false,'no job fixture'));
    }

    g.push(await check(15,'no_stale_active_dispatch_jobs',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_effective_dispatch_jobs q
        left join retail.effective_compiled_search_jobs ec
          on ec.id=q.compilation_id
        where ec.id is null
      `)).ok===true));

    g.push(await check(16,'no_job_hash_drift',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_dispatch_jobs q
        join retail.effective_compiled_search_jobs ec
          on ec.id=q.compilation_id
        where q.status in('queued','retry_wait','leased','dispatching')
          and (
            q.route_authority_hash<>ec.route_authority_hash
            or q.adapter_payload_sha256<>ec.adapter_payload_sha256
            or q.compiler_authority_sha256<>ec.compiler_authority_sha256
          )
      `)).ok===true));

    g.push(await check(17,'cost_evidence_hashes_reproducible',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_cost_profiles
        where evidence_sha256<>retail.r1d_sha256_jsonb(evidence_json)
      `)).ok===true));

    g.push(await check(18,'no_negative_budget_values',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_budget_reservations
        where reserved_usd<0 or actual_usd<0
      `)).ok===true));

    g.push(await check(19,'no_multiple_active_global_budgets',
      (await one(c,`
        select count(*)<=1 ok
        from retail.r1d_budget_policies
        where active and scope_type='GLOBAL'
      `)).ok===true));

    g.push(await check(20,'no_budget_over_limit_current_day',
      (await one(c,`
        select count(*)=0 ok
        from (
          select p.id,p.daily_limit_usd,
            coalesce(sum(
              case
                when r.status='settled' then coalesce(r.actual_usd,r.reserved_usd)
                when r.status='reserved' then r.reserved_usd
                else 0
              end
            ),0) used
          from retail.r1d_budget_policies p
          left join retail.r1d_budget_reservations r
            on r.budget_policy_id=p.id
           and r.budget_day=(now() at time zone 'UTC')::date
          where p.active
          group by p.id,p.daily_limit_usd
        ) x
        where x.used>x.daily_limit_usd
      `)).ok===true));

    g.push(await check(21,'rate_usage_nonnegative',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_rate_usage where reserved_count<0
      `)).ok===true));

    g.push(await check(22,'hourly_rate_limits_not_exceeded',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_rate_usage u
        join retail.retail_platforms p on p.id=u.platform_id
        where u.bucket_kind='hour'
          and p.max_hourly_requests is not null
          and u.reserved_count>p.max_hourly_requests
      `)).ok===true));

    g.push(await check(23,'daily_rate_limits_not_exceeded',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_rate_usage u
        join retail.retail_platforms p on p.id=u.platform_id
        where u.bucket_kind='day'
          and p.max_daily_requests is not null
          and u.reserved_count>p.max_daily_requests
      `)).ok===true));

    g.push(await check(24,'leased_jobs_have_complete_lease',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_dispatch_jobs
        where status in('leased','dispatching')
          and (
            lease_token is null or leased_by is null
            or leased_at is null or lease_expires_at is null
          )
      `)).ok===true));

    g.push(await check(25,'terminal_jobs_have_no_active_lease',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_dispatch_jobs
        where status in('succeeded','dead_letter','cancelled')
          and lease_expires_at>now()
      `)).ok===true));

    g.push(await check(26,'no_duplicate_attempt_numbers',
      (await one(c,`
        select count(*)=0 ok
        from (
          select job_id,attempt_no,count(*)
          from retail.r1d_dispatch_attempts
          group by job_id,attempt_no
          having count(*)>1
        ) x
      `)).ok===true));

    g.push(await check(27,'dead_letter_rows_match_terminal_jobs',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_dead_letters d
        join retail.r1d_dispatch_jobs j on j.id=d.job_id
        where j.status<>'dead_letter'
      `)).ok===true));

    g.push(await check(28,'schedule_state_only_current_or_retired',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_compilation_schedule_state s
        where s.activation_state<>'retired'
          and not exists(
            select 1 from retail.effective_compiled_search_jobs ec
            where ec.id=s.compilation_id
          )
      `)).ok===true));

    g.push(await check(29,'only_one_current_binding_per_adapter',
      (await one(c,`
        select count(*)=0 ok
        from (
          select adapter_id,count(*)
          from retail.r1d_dispatch_bindings
          where certification_status='certified'
          group by adapter_id
          having count(*)>1
        ) x
      `)).ok===true));

    g.push(await mustFail(c,30,'invalid_geo_state_rejected',
      ()=>c.query(`
        select retail.r1d_set_geo_activation(
          gen_random_uuid(),'INVALID','manual',null,'qa'
        )
      `)));

    g.push(await mustFail(c,31,'geo_escalation_fanout_cap_enforced',
      ()=>c.query(`
        select retail.r1d_activate_geo_children(
          gen_random_uuid(),'QA',1,'qa',101,'qa',
          gen_random_uuid(),'qa'
        )
      `)));

    g.push(await mustFail(c,32,'negative_actual_cost_rejected',
      ()=>c.query(`
        select retail.r1d_settle_budget(
          gen_random_uuid(),-1,'actual',gen_random_uuid(),'qa'
        )
      `)));

    g.push(await mustFail(c,33,'invalid_cost_basis_rejected',
      ()=>c.query(`
        select retail.r1d_settle_budget(
          gen_random_uuid(),1,'bogus',gen_random_uuid(),'qa'
        )
      `)));

    g.push(await check(34,'circuit_breaker_state_valid',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_circuit_breakers
        where state not in('closed','open','half_open')
      `)).ok===true));

    g.push(await check(35,'outbox_payload_hashes_reproducible',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_dispatch_outbox
        where payload_sha256<>retail.r1d_sha256_jsonb(payload_json)
      `)).ok===true));

    g.push(await check(36,'no_scheduler_fields_in_r1c_mutated',
      (await one(c,`
        select count(*)=0 ok
        from information_schema.columns
        where table_schema='retail'
          and table_name='search_job_compilations'
          and (
            column_name ilike '%lease%'
            or column_name ilike '%budget%'
            or column_name ilike '%dispatch%'
          )
      `)).ok===true));

    g.push(await check(37,'r1d_has_no_purchase_authority',
      (await one(c,`
        select count(*)=0 ok
        from information_schema.columns
        where table_schema='retail'
          and table_name like 'r1d_%'
          and (
            column_name ilike '%buy_price%'
            or column_name ilike '%purchase_authorization%'
            or column_name ilike '%checkout%'
          )
      `)).ok===true));

    g.push(await check(38,'effective_dispatch_view_exists',
      (await one(c,`
        select to_regclass('retail.r1d_effective_dispatch_jobs') is not null ok
      `)).ok===true));

    g.push(await check(39,'budget_ledger_append_only_structure',
      (await one(c,`
        select to_regclass('retail.r1d_budget_ledger') is not null ok
      `)).ok===true));

    g.push(await check(40,'geo_activation_evidence_exists',
      (await one(c,`
        select to_regclass('retail.r1d_geo_activation_events') is not null ok
      `)).ok===true));

    g.push(await check(41,'public_claim_execute_revoked',
      (await one(c,`
        select has_function_privilege(
          'public','retail.r1d_claim_next_job(text,uuid,text)','EXECUTE'
        )=false ok
      `)).ok===true));

    g.push(await check(42,'public_finish_execute_revoked',
      (await one(c,`
        select has_function_privilege(
          'public',
          'retail.r1d_finish_job(uuid,uuid,boolean,numeric,text,text,text,jsonb,integer,text,text,text,text,uuid,text)',
          'EXECUTE'
        )=false ok
      `)).ok===true));

    g.push(await check(43,'public_materialize_execute_revoked',
      (await one(c,`
        select has_function_privilege(
          'public',
          'retail.r1d_materialize_due_jobs(timestamptz,integer,uuid,text,text)',
          'EXECUTE'
        )=false ok
      `)).ok===true));

    g.push(await check(44,'audit_triggers_present',
      (await one(c,`
        select count(*)>=7 ok
        from pg_trigger
        where tgname like 'trg_r1d_audit_%'
          and not tgisinternal
      `)).ok===true));

    g.push(await check(45,'r1c_binding_history_exists',
      (await one(c,`
        select to_regclass('retail.r1d_r1c_binding_history') is not null ok
      `)).ok===true));

    g.push(await check(46,'certification_table_exists',
      (await one(c,`
        select to_regclass('retail.r1d_certification_runs') is not null ok
      `)).ok===true));

    g.push(await check(47,'all_effective_jobs_have_schedule_state',
      (await one(c,`
        select count(*)=0 ok
        from retail.effective_compiled_search_jobs ec
        where not exists(
          select 1 from retail.r1d_compilation_schedule_state s
          where s.compilation_id=ec.id
        )
      `)).ok===true));

    g.push(await check(48,'active_schedule_state_has_active_policy',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_compilation_schedule_state s
        join retail.r1d_schedule_policies p on p.id=s.schedule_policy_id
        where s.activation_state in('baseline','activated')
          and p.active is not true
      `)).ok===true));

    g.push(await check(49,'queued_jobs_have_current_binding',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_dispatch_jobs j
        where j.status in('queued','retry_wait','leased','dispatching')
          and retail.r1d_dispatch_binding_is_current(j.dispatch_binding_id) is not true
      `)).ok===true));

    g.push(await check(50,'queued_jobs_have_current_compilation',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_dispatch_jobs j
        where j.status in('queued','retry_wait','leased','dispatching')
          and not exists(
            select 1 from retail.effective_compiled_search_jobs ec
            where ec.id=j.compilation_id
          )
      `)).ok===true));


    const packageBinding=(await c.query(`
      select b.id,a.id adapter_id,s.package_tree_sha256
      from retail.r1d_dispatch_bindings b
      join retail.retail_search_adapters a on a.id=b.adapter_id
      join retail.retail_scraper_assets s on s.id=b.scraper_asset_id
      where retail.r1d_dispatch_binding_is_current(b.id)=true
        and s.implementation_authority_type='package_tree'
      limit 1
    `)).rows[0];

    if(packageBinding){
      g.push(await mustFail(c,51,'wrong_package_tree_sha_rejected',
        ()=>c.query(`
          select retail.r1b_assert_runtime_adapter(
            $1,repeat('0',64)
          )
        `,[packageBinding.adapter_id])));
    }else{
      g.push(await check(51,'wrong_package_tree_sha_rejected',false,'no package-tree binding fixture'));
    }

    g.push(await mustFail(c,52,'invalid_lease_completion_rejected',
      ()=>c.query(`
        select retail.r1d_mark_dispatching(
          gen_random_uuid(),gen_random_uuid()
        )
      `)));

    g.push(await check(53,'budget_reservation_group_not_reused_after_release',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_dispatch_jobs j
        where j.budget_reservation_group is not null
          and not exists(
            select 1 from retail.r1d_budget_reservations r
            where r.reservation_group=j.budget_reservation_group
              and r.status='reserved'
          )
      `)).ok===true));

    g.push(await check(54,'terminal_budget_reservations_not_left_reserved',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_dispatch_jobs j
        join retail.r1d_budget_reservations r on r.job_id=j.id
        where j.status in('succeeded','dead_letter','cancelled')
          and r.status='reserved'
      `)).ok===true));

    g.push(await check(55,'single_certified_binding_per_adapter',
      (await one(c,`
        select count(*)=0 ok
        from (
          select adapter_id,count(*)
          from retail.r1d_dispatch_bindings
          where certification_status='certified'
          group by adapter_id
          having count(*)>1
        ) x
      `)).ok===true));

    await c.query('rollback');

    const pass=g.every(x=>x.ok);
    console.log(JSON.stringify({
      suite:'R1D_V1_FREEZE',
      gates:g,
      passed:g.filter(x=>x.ok).length,
      failed:g.filter(x=>!x.ok).length,
      allPassed:pass
    },null,2));

    if(!pass) process.exitCode=2;
  }finally{
    c.release();await pool.end();
  }
}

main().catch(e=>{
  console.error(e);
  process.exitCode=1;
});
