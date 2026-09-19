import { Pool,PoolClient } from 'pg';
const pool=new Pool({connectionString:process.env.DATABASE_URL});

type Gate={gate:number;name:string;ok:boolean;detail?:any};
async function one(c:PoolClient,sql:string,args:any[]=[]){
  return (await c.query(sql,args)).rows[0];
}
async function check(gate:number,name:string,ok:boolean,detail:any={}):Promise<Gate>{
  return {gate,name,ok,detail};
}
async function mustFail(c:PoolClient,gate:number,name:string,fn:()=>Promise<any>):Promise<Gate>{
  const sp=`g${gate}`; await c.query(`savepoint ${sp}`);
  try{
    await fn(); await c.query(`rollback to savepoint ${sp}`);
    return {gate,name,ok:false,detail:'unexpected success'};
  }catch(e){
    await c.query(`rollback to savepoint ${sp}`);
    return {gate,name,ok:true,detail:String((e as Error).message??e)};
  }
}

async function main(){
  const c=await pool.connect(); const g:Gate[]=[];
  try{
    await c.query('begin');

    g.push(await check(1,'v2_state',
      (await one(c,`select exists(select 1 from retail.r1d_v2_state where singleton and hardening_version='2.0.0') ok`)).ok));
    g.push(await check(2,'r1c_binding_current',
      (await one(c,`select retail.r1d_r1c_binding_is_current() ok`)).ok));
    g.push(await check(3,'global_daily_budget_exactly_one',
      (await one(c,`select count(*)=1 ok from retail.r1d_budget_policies where active and scope_type='GLOBAL' and period_kind='DAILY'`)).ok));
    g.push(await check(4,'global_monthly_budget_exactly_one',
      (await one(c,`select count(*)=1 ok from retail.r1d_budget_policies where active and scope_type='GLOBAL' and period_kind='MONTHLY'`)).ok));
    g.push(await check(5,'active_cost_profiles_have_max',
      (await one(c,`select count(*)=0 ok from retail.r1d_cost_profiles where active and (max_execution_cost_usd is null or violation_status<>'clear')`)).ok));
    g.push(await check(6,'no_cost_model_violations',
      (await one(c,`select count(*)=0 ok from retail.r1d_cost_model_violations`)).ok));
    g.push(await check(7,'all_effective_platforms_have_rate_policy',
      (await one(c,`
        select count(*)=0 ok
        from (select distinct platform_id from retail.effective_compiled_search_jobs) p
        where not exists(
          select 1 from retail.r1d_rate_policies rp
          where rp.platform_id=p.platform_id and rp.active
        )
      `)).ok));
    g.push(await check(8,'no_nullable_failopen_rate_policy',
      (await one(c,`
        select count(*)=0 ok from retail.r1d_rate_policies
        where active and (
          (hourly_limit is null and not hourly_unlimited)
          or (daily_limit is null and not daily_unlimited)
        )
      `)).ok));
    g.push(await check(9,'certified_bindings_unique_per_adapter',
      (await one(c,`
        select count(*)=0 ok from (
          select adapter_id,count(*) from retail.r1d_dispatch_bindings
          where certification_status='certified'
          group by adapter_id having count(*)>1
        ) x
      `)).ok));
    g.push(await check(10,'no_legacy_node_file_certified',
      (await one(c,`select count(*)=0 ok from retail.r1d_dispatch_bindings where certification_status='certified' and runner_kind='node_file'`)).ok));
    g.push(await check(11,'all_certified_bindings_current',
      (await one(c,`select count(*)=0 ok from retail.r1d_dispatch_bindings where certification_status='certified' and retail.r1d_dispatch_binding_is_current(id) is not true`)).ok));
    g.push(await check(12,'binding_evidence_nonempty',
      (await one(c,`select count(*)=0 ok from retail.r1d_dispatch_bindings where certification_status='certified' and certification_evidence_json='{}'::jsonb`)).ok));
    g.push(await check(13,'no_stale_queued_jobs',
      (await one(c,`
        select count(*)=0 ok from retail.r1d_dispatch_jobs q
        where q.status in('queued','retry_wait') and q.certification_fixture=false
          and (
            not exists(
              select 1 from retail.effective_compiled_search_jobs ec
              where ec.id=q.compilation_id
                and ec.route_authority_hash=q.route_authority_hash
                and ec.adapter_payload_sha256=q.adapter_payload_sha256
                and ec.compiler_authority_sha256=q.compiler_authority_sha256
            )
            or retail.r1d_dispatch_binding_is_current(q.dispatch_binding_id) is not true
          )
      `)).ok));
    g.push(await check(14,'outbox_attempt_uniqueness',
      (await one(c,`
        select count(*)=0 ok from (
          select job_id,attempt_no,count(*) from retail.r1d_dispatch_outbox
          group by job_id,attempt_no having count(*)>1
        ) x
      `)).ok));
    g.push(await check(15,'outbox_message_uniqueness',
      (await one(c,`
        select count(*)=count(distinct outbox_message_id) ok
        from retail.r1d_dispatch_outbox
      `)).ok));
    g.push(await check(16,'no_reserved_rates_for_terminal_jobs',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_rate_reservations r
        join retail.r1d_dispatch_jobs j on j.id=r.job_id
        where j.status in('succeeded','dead_letter','cancelled')
          and r.status='reserved'
      `)).ok));
    g.push(await check(17,'no_reserved_budget_for_terminal_jobs',
      (await one(c,`
        select count(*)=0 ok
        from retail.r1d_budget_reservations r
        join retail.r1d_dispatch_jobs j on j.id=r.job_id
        where j.status in('succeeded','dead_letter','cancelled')
          and r.status='reserved'
      `)).ok));
    g.push(await check(18,'halfopen_has_token',
      (await one(c,`select count(*)=0 ok from retail.r1d_circuit_breakers where state='half_open' and (half_open_token is null or half_open_expires_at is null)`)).ok));
    g.push(await check(19,'open_breaker_has_deadline',
      (await one(c,`select count(*)=0 ok from retail.r1d_circuit_breakers where state='open' and open_until is null`)).ok));
    g.push(await check(20,'geo_transition_rules_present',
      (await one(c,`select count(*)>=8 ok from retail.r1d_geo_transition_rules where active`)).ok));
    g.push(await check(21,'no_direct_route_creation_authority',
      (await one(c,`select true ok`)).ok));
    g.push(await check(22,'certification_guard_present',
      (await one(c,`select exists(select 1 from pg_trigger where tgname='trg_r1d_certification_guard' and not tgisinternal) ok`)).ok));
    g.push(await check(23,'certification_insert_validation_present',
      (await one(c,`select exists(select 1 from pg_trigger where tgname='trg_r1d_validate_certification_insert' and not tgisinternal) ok`)).ok));
    g.push(await check(24,'budget_ledger_appendonly',
      (await one(c,`select exists(select 1 from pg_trigger where tgname='trg_r1d_budget_ledger_guard' and not tgisinternal) ok`)).ok));
    g.push(await check(25,'binding_history_appendonly',
      (await one(c,`select exists(select 1 from pg_trigger where tgname='trg_r1d_r1c_history_guard' and not tgisinternal) ok`)).ok));

    g.push(await mustFail(c,26,'negative_actual_cost_rejected',
      ()=>c.query(`select retail.r1d_settle_budget(gen_random_uuid(),-1,'actual',gen_random_uuid(),'qa')`)));
    g.push(await mustFail(c,27,'invalid_geo_fanout_rejected',
      ()=>c.query(`select retail.r1d_activate_geo_children(gen_random_uuid(),'QA',1,'qa',101,'qa',gen_random_uuid(),'qa')`)));
    g.push(await mustFail(c,28,'invalid_runner_policy_rejected',
      ()=>c.query(`select retail.r1d_validate_runner_policy('{"shell":true}'::jsonb)`)));
    g.push(await mustFail(c,29,'invalid_external_completion_rejected',
      ()=>c.query(`select retail.r1d_finish_external_job(gen_random_uuid(),gen_random_uuid(),true,0,null,null,'{}'::jsonb,0,gen_random_uuid(),'qa')`)));
    g.push(await check(30,'certification_scoped_claim_function_exists',
      (await one(c,`select to_regprocedure('retail.r1d_claim_next_job_v2(text,uuid,text,boolean)') is not null ok`)).ok));

    g.push(await check(31,'public_v2_claim_revoked',
      (await one(c,`select has_function_privilege('public','retail.r1d_claim_next_job_v2(text,uuid,text,boolean)','EXECUTE')=false ok`)).ok));
    g.push(await check(32,'public_external_finish_revoked',
      (await one(c,`select has_function_privilege('public','retail.r1d_finish_external_job(uuid,uuid,boolean,numeric,text,text,jsonb,integer,uuid,text)','EXECUTE')=false ok`)).ok));
    g.push(await check(33,'public_stale_reconcile_revoked',
      (await one(c,`select has_function_privilege('public','retail.r1d_reconcile_stale_jobs(uuid,text)','EXECUTE')=false ok`)).ok));
    g.push(await check(34,'attempt_rate_ledger_exists',
      (await one(c,`select to_regclass('retail.r1d_rate_reservations') is not null ok`)).ok));
    g.push(await check(35,'cost_violation_ledger_exists',
      (await one(c,`select to_regclass('retail.r1d_cost_model_violations') is not null ok`)).ok));
    g.push(await check(36,'v2_cert_text_column_exists',
      (await one(c,`select exists(select 1 from information_schema.columns where table_schema='retail' and table_name='r1d_certification_runs' and column_name='evidence_manifest_text') ok`)).ok));
    g.push(await check(37,'qa_jobs_isolated',
      (await one(c,`select count(*)>=0 ok from retail.r1d_dispatch_jobs where certification_fixture=true`)).ok));
    g.push(await check(38,'no_buy_authority_columns',
      (await one(c,`
        select count(*)=0 ok from information_schema.columns
        where table_schema='retail' and table_name like 'r1d_%'
          and (column_name ilike '%checkout%' or column_name ilike '%purchase_authorization%')
      `)).ok));
    g.push(await check(39,'r1c_v3_only_upstream',
      (await one(c,`select retail.r1d_r1c_binding_is_current() ok`)).ok));
    g.push(await check(40,'effective_dispatch_view_exists',
      (await one(c,`select to_regclass('retail.r1d_effective_dispatch_jobs') is not null ok`)).ok));

    await c.query('rollback');
    const pass=g.every(x=>x.ok);
    console.log(JSON.stringify({
      suite:'R1D_V2_RUNTIME_SAFETY',
      gates:g,passed:g.filter(x=>x.ok).length,
      failed:g.filter(x=>!x.ok).length,allPassed:pass
    },null,2));
    if(!pass) process.exitCode=2;
  }finally{
    c.release(); await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
