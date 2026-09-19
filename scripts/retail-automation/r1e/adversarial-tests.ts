import { Pool,PoolClient } from 'pg';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [rulesetId]=process.argv.slice(2);
if(!rulesetId) throw new Error('usage: tsx adversarial-tests.ts <ruleset_uuid>');

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

    const rs=(await c.query(`
      select * from retail.r1e_match_rulesets
      where id=$1 and certification_status='certified'
    `,[rulesetId])).rows[0];

    g.push(await check(1,'r1e_schema_current',
      (await one(c,`select exists(select 1 from retail.r1e_schema_state where singleton and schema_version='1.0.0') ok`)).ok));
    g.push(await check(2,'r1d_binding_current',
      (await one(c,`select retail.r1e_r1d_binding_is_current() ok`)).ok));
    g.push(await check(3,'certified_ruleset_fixture',!!rs));
    g.push(await check(4,'ruleset_hash_reproducible',
      !!rs && (await one(c,`
        select rules_sha256=retail.r1e_sha256_jsonb(rules_json) ok
        from retail.r1e_match_rulesets where id=$1
      `,[rulesetId])).ok===true));

    if(rs){
      g.push(await mustFail(c,5,'certified_ruleset_business_mutation',
        ()=>c.query(`update retail.r1e_match_rulesets set rules_json='{}'::jsonb where id=$1`,[rulesetId])));
      g.push(await mustFail(c,6,'certified_ruleset_delete',
        ()=>c.query(`delete from retail.r1e_match_rulesets where id=$1`,[rulesetId])));

      const positive={
        brand:'Dell',model_family:'Latitude 7450',
        exclude_terms:[],allowed_conditions:['new']
      };
      const returned={
        title:'Dell Latitude 7450 Laptop 16GB',
        brand:'Dell',model_number:'Latitude 7450',sku:'X1',condition:'new'
      };

      const a=(await one(c,`
        select retail.r1e_match_documents($1::jsonb,$2::jsonb,rules_json,false) r
        from retail.r1e_match_rulesets where id=$3
      `,[JSON.stringify(positive),JSON.stringify(returned),rulesetId])).r;
      const b=(await one(c,`
        select retail.r1e_match_documents($1::jsonb,$2::jsonb,rules_json,false) r
        from retail.r1e_match_rulesets where id=$3
      `,[JSON.stringify(positive),JSON.stringify(returned),rulesetId])).r;

      g.push(await check(7,'positive_identity_qualified',a.decision==='QUALIFIED',a));
      g.push(await check(8,'match_deterministic',JSON.stringify(a)===JSON.stringify(b)));

      const wrongBrand=(await one(c,`
        select retail.r1e_match_documents(
          $1::jsonb,
          '{"title":"HP EliteBook 840","brand":"HP","model_number":"840"}'::jsonb,
          rules_json,false
        ) r
        from retail.r1e_match_rulesets where id=$2
      `,[JSON.stringify(positive),rulesetId])).r;
      g.push(await check(9,'wrong_brand_rejected',wrongBrand.decision==='REJECTED_IDENTITY',wrongBrand));

      const accessory=(await one(c,`
        select retail.r1e_match_documents(
          $1::jsonb,
          '{"title":"Protective Case for Dell Latitude 7450","brand":"Generic"}'::jsonb,
          rules_json,false
        ) r
        from retail.r1e_match_rulesets where id=$2
      `,[JSON.stringify({...positive,exclude_terms:['case']}),rulesetId])).r;
      g.push(await check(10,'accessory_rejected',accessory.decision==='REJECTED_ACCESSORY',accessory));

      const condition=(await one(c,`
        select retail.r1e_match_documents(
          $1::jsonb,
          '{"title":"Dell Latitude 7450","brand":"Dell","model_number":"Latitude 7450","condition":"used"}'::jsonb,
          rules_json,false
        ) r
        from retail.r1e_match_rulesets where id=$2
      `,[JSON.stringify(positive),rulesetId])).r;
      g.push(await check(11,'condition_rejected',condition.decision==='REJECTED_CONDITION',condition));

      const duplicate=(await one(c,`
        select retail.r1e_match_documents($1::jsonb,$2::jsonb,rules_json,true) r
        from retail.r1e_match_rulesets where id=$3
      `,[JSON.stringify(positive),JSON.stringify(returned),rulesetId])).r;
      g.push(await check(12,'duplicate_rejected',duplicate.decision==='REJECTED_DUPLICATE',duplicate));

      const incomplete=(await one(c,`
        select retail.r1e_match_documents(
          $1::jsonb,'{"brand":"Dell"}'::jsonb,rules_json,false
        ) r
        from retail.r1e_match_rulesets where id=$2
      `,[JSON.stringify(positive),rulesetId])).r;
      g.push(await check(13,'incomplete_rejected',incomplete.decision==='REJECTED_INCOMPLETE',incomplete));

      g.push(await mustFail(c,14,'invalid_ruleset_weights_rejected',
        ()=>c.query(`
          select retail.r1e_validate_ruleset(
            jsonb_set(rules_json,'{identity,weights,brand}','0.9'::jsonb)
          )
          from retail.r1e_match_rulesets where id=$1
        `,[rulesetId])));
    }else{
      for(let i=5;i<=14;i++) g.push(await check(i,`ruleset_fixture_required_${i}`,false));
    }

    g.push(await check(15,'pending_capture_view_exists',
      (await one(c,`select to_regclass('retail.r1e_pending_captures') is not null ok`)).ok));
    g.push(await check(16,'effective_output_view_exists',
      (await one(c,`select to_regclass('retail.r1e_effective_qualified_products') is not null ok`)).ok));
    g.push(await check(17,'results_immutable_trigger',
      (await one(c,`select exists(select 1 from pg_trigger where tgname='trg_r1e_result_guard' and not tgisinternal) ok`)).ok));
    g.push(await check(18,'certification_append_only',
      (await one(c,`select exists(select 1 from pg_trigger where tgname='trg_r1e_certification_guard' and not tgisinternal) ok`)).ok));
    g.push(await check(19,'binding_history_append_only',
      (await one(c,`select exists(select 1 from pg_trigger where tgname='trg_r1e_binding_history_guard' and not tgisinternal) ok`)).ok));
    g.push(await check(20,'fixture_hashes_reproducible',
      (await one(c,`
        select count(*)=0 ok from retail.r1e_qa_fixtures f
        where f.active and f.fixture_sha256<>
          retail.r1e_sha256_jsonb(retail.r1e_fixture_document(f))
      `)).ok));
    g.push(await check(21,'qualification_evidence_hashes_reproducible',
      (await one(c,`
        select count(*)=0 ok from retail.r1e_qualification_results
        where evidence_sha256<>retail.r1e_sha256_jsonb(evidence_json)
      `)).ok));
    g.push(await check(22,'no_multiple_qualified_duplicates',
      (await one(c,`
        select count(*)=0 ok from (
          select ruleset_id,duplicate_fingerprint,count(*)
          from retail.r1e_qualification_results
          where decision='QUALIFIED'
          group by ruleset_id,duplicate_fingerprint
          having count(*)>1
        ) x
      `)).ok));
    g.push(await check(23,'qualified_rows_have_canonical_product',
      (await one(c,`
        select count(*)=0 ok from retail.r1e_qualification_results
        where decision='QUALIFIED' and retail_product_id is null
      `)).ok));
    g.push(await check(24,'result_lineage_complete',
      (await one(c,`
        select count(*)=0 ok from retail.r1e_qualification_results q
        where q.source_process_run_id is null
           or q.source_correlation_id is null
           or (q.evidence_json->>'collection_run_id') is null
           or (q.evidence_json->>'r1d_attempt_id') is null
      `)).ok));
    g.push(await check(25,'rejected_rows_explainable',
      (await one(c,`
        select count(*)=0 ok from retail.r1e_qualification_results
        where decision<>'QUALIFIED'
          and jsonb_array_length(reason_codes)=0
      `)).ok));
    g.push(await check(26,'public_evaluate_execute_revoked',
      (await one(c,`
        select has_function_privilege(
          'public',
          'retail.r1e_evaluate_capture(uuid,uuid,uuid,text,text)',
          'EXECUTE'
        )=false ok
      `)).ok));
    g.push(await check(27,'public_bind_execute_revoked',
      (await one(c,`
        select has_function_privilege(
          'public',
          'retail.r1e_bind_r1d_certification(uuid,uuid,text,text)',
          'EXECUTE'
        )=false ok
      `)).ok));
    g.push(await check(28,'certification_policy_exists',
      (await one(c,`select count(*)=1 ok from retail.r1e_certification_policy where singleton`)).ok));
    g.push(await check(29,'no_profit_columns',
      (await one(c,`
        select count(*)=0 ok
        from information_schema.columns
        where table_schema='retail'
          and table_name like 'r1e_%'
          and (
            column_name ilike '%profit%'
            or column_name ilike '%margin%'
            or column_name ilike '%roi%'
          )
      `)).ok));
    g.push(await check(30,'no_purchase_authority_columns',
      (await one(c,`
        select count(*)=0 ok
        from information_schema.columns
        where table_schema='retail'
          and table_name like 'r1e_%'
          and (
            column_name ilike '%buy%'
            or column_name ilike '%purchase%'
            or column_name ilike '%checkout%'
            or column_name ilike '%capital%'
          )
      `)).ok));
    g.push(await check(31,'no_demand_authority_columns',
      (await one(c,`
        select count(*)=0 ok
        from information_schema.columns
        where table_schema='retail'
          and table_name like 'r1e_%'
          and column_name ilike '%demand%'
      `)).ok));
    g.push(await check(32,'certified_ruleset_unique',
      (await one(c,`
        select count(*)=0 ok from (
          select ruleset_code,count(*)
          from retail.r1e_match_rulesets
          where certification_status='certified'
          group by ruleset_code having count(*)>1
        ) x
      `)).ok));
    g.push(await check(33,'downstream_output_requires_r1e_certification',
      (await one(c,`
        select pg_get_viewdef('retail.r1e_effective_qualified_products'::regclass,true)
          like '%r1e_latest_certification_is_current%' ok
      `)).ok));
    g.push(await check(34,'raw_payload_hash_bound_in_evidence',
      (await one(c,`
        select count(*)=0 ok from retail.r1e_qualification_results
        where (evidence_json->>'raw_payload_hash') is null
      `)).ok));
    g.push(await check(35,'ruleset_hash_bound_in_evidence',
      (await one(c,`
        select count(*)=0 ok from retail.r1e_qualification_results
        where (evidence_json->>'ruleset_sha256') is null
      `)).ok));

    await c.query('rollback');
    const pass=g.every(x=>x.ok);
    console.log(JSON.stringify({
      suite:'R1E_V1_FREEZE',
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

main().catch(e=>{console.error(e);process.exitCode=1;});
