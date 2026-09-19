import { Pool } from 'pg';
const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [rulesetId]=process.argv.slice(2);
if(!rulesetId) throw new Error('usage: tsx adversarial-tests-v2.ts <ruleset_uuid>');

async function main(){
  const g:any[]=[];
  const push=(name:string,ok:boolean,detail:any={})=>g.push({name,ok,detail});
  const one=async(sql:string,args:any[]=[])=>(await pool.query(sql,args)).rows[0];

  push('v2_state',(await one(`select exists(select 1 from retail.r1e_v2_state where singleton and hardening_version='2.0.0') ok`)).ok);
  push('r1d_binding_current',(await one(`select retail.r1e_r1d_binding_is_current() ok`)).ok);
  push('ruleset_current',(await one(`select exists(select 1 from retail.r1e_match_rulesets where id=$1 and certification_status='certified' and rules_sha256=retail.r1e_sha256_jsonb(rules_json)) ok`,[rulesetId])).ok);
  push('cert_policy_current',(await one(`select count(*)=1 ok from retail.r1e_certification_policies where certification_status='certified'`)).ok);
  push('safe_uuid_malformed',(await one(`select retail.r1e_try_uuid('not-a-uuid') is null ok`)).ok);
  push('observation_unique_index',(await one(`select exists(select 1 from pg_indexes where schemaname='retail' and indexname='uq_r1e_v2_one_qualified_observation') ok`)).ok);
  push('result_upstream_columns',(await one(`select count(*)=8 ok from information_schema.columns where table_schema='retail' and table_name='r1e_qualification_results' and column_name in('r1d_certification_run_id','r1d_package_sha256','r1c_compilation_key','route_authority_hash','r1a_revision_id','r1a_revision_hash','ruleset_sha256','engine_version')`)).ok);
  push('attempt_evidence_columns',(await one(`select count(*)=2 ok from information_schema.columns where table_schema='retail' and table_name='r1e_qualification_results' and column_name in('r1d_attempt_evidence_json','r1d_attempt_evidence_sha256')`)).ok);
  push('immutable_snapshot_view',(await one(`select pg_get_viewdef('retail.r1e_effective_qualified_products'::regclass,true) not like '%retail_products%' ok`)).ok);
  push('currentness_exact_r1d',(await one(`select pg_get_functiondef('retail.r1e_latest_certification_is_current(uuid)'::regprocedure) like '%cr.r1d_certification_run_id=b.r1d_certification_run_id%' ok`)).ok);
  push('currentness_exact_package',(await one(`select pg_get_functiondef('retail.r1e_latest_certification_is_current(uuid)'::regprocedure) like '%cr.r1d_package_sha256=b.r1d_package_sha256%' ok`)).ok);
  push('process_validation',(await one(`select to_regprocedure('retail.r1e_assert_process_run(uuid,text[])') is not null ok`)).ok);
  push('phrase_matcher',(await one(`select retail.r1e_contains_phrase('protective case for laptop','case') ok`)).ok);
  push('phrase_boundary',(await one(`select retail.r1e_contains_phrase('showcase laptop','case')=false ok`)).ok);

    const rulesObj=(await pool.query(`select rules_json from retail.r1e_match_rulesets where id=$1`,[rulesetId])).rows[0]?.rules_json;
  if(rulesObj){
    const target={
      brand:'Apple',model_family:'iPhone 15 Pro Max',
      normalized_identity:{normalized_model_token:'iphone 15 pro max',generation:'15',variant:'pro max',storage:'256gb',platform:'ios'},
      allowed_product_conditions:['new']
    };
    const wrong={title:'Apple iPhone 15 Pro Max 128GB',brand:'Apple',model_number:'iPhone 15 Pro Max',generation:'15',variant:'pro max',storage:'128gb',platform:'ios',condition:'new'};
    const r=await one(`select retail.r1e_match_documents_v2($1::jsonb,$2::jsonb,$3::jsonb,false) r`,[JSON.stringify(target),JSON.stringify(wrong),JSON.stringify(rulesObj)]);
    push('wrong_storage_hard_reject',r.r.decision==='REJECTED_IDENTITY',r.r);

    const idTarget={brand:'Dell',model_family:'Latitude 7450',identifiers:{upc:'111'},allowed_product_conditions:['new']};
    const idReturned={title:'Dell Latitude 7450',brand:'Dell',model_number:'Latitude 7450',upc:'222',condition:'new'};
    const ir=await one(`select retail.r1e_match_documents_v2($1::jsonb,$2::jsonb,$3::jsonb,false) r`,[JSON.stringify(idTarget),JSON.stringify(idReturned),JSON.stringify(rulesObj)]);
    push('identifier_mismatch_hard_reject',ir.r.decision==='REJECTED_IDENTITY',ir.r);
  }else{
    push('wrong_storage_hard_reject',false,'no ruleset');
    push('identifier_mismatch_hard_reject',false,'no ruleset');
  }

  push('policy_hash_reproducible',(await one(`select count(*)=0 ok from retail.r1e_certification_policies where certification_status='certified' and policy_sha256<>retail.r1e_sha256_jsonb(policy_json)`)).ok);
  const binding=(await pool.query(`select * from retail.r1e_r1d_certification_binding where singleton=true`)).rows[0];
  if(binding){
    push('upstream_rebind_run_mismatch_invalidates',
      (await one(`select retail.r1e_upstream_identity_is_current(gen_random_uuid(),$1)=false ok`,[binding.r1d_package_sha256])).ok);
    push('upstream_rebind_package_mismatch_invalidates',
      (await one(`select retail.r1e_upstream_identity_is_current($1,repeat('0',64))=false ok`,[binding.r1d_certification_run_id])).ok);
  }else{
    push('upstream_rebind_run_mismatch_invalidates',false,'no binding');
    push('upstream_rebind_package_mismatch_invalidates',false,'no binding');
  }
  push('observation_fingerprint_binds_context',
    (await one(`select pg_get_functiondef('retail.r1e_observation_document(retail.raw_product_captures,retail.search_job_compilations,retail.retail_products)'::regprocedure) like '%collection_run_id%' and pg_get_functiondef('retail.r1e_observation_document(retail.raw_product_captures,retail.search_job_compilations,retail.retail_products)'::regprocedure) like '%effective_price%' and pg_get_functiondef('retail.r1e_observation_document(retail.raw_product_captures,retail.search_job_compilations,retail.retail_products)'::regprocedure) like '%location%' ok`)).ok);
  push('result_evidence_hashes',(await one(`select count(*)=0 ok from retail.r1e_qualification_results where engine_version='r1e-v2.0.0' and evidence_sha256<>retail.r1e_sha256_jsonb(evidence_json)`)).ok);
  push('attempt_evidence_hashes',(await one(`select count(*)=0 ok from retail.r1e_qualification_results where engine_version='r1e-v2.0.0' and r1d_attempt_evidence_sha256<>retail.r1e_sha256_jsonb(r1d_attempt_evidence_json)`)).ok);
  push('no_duplicate_qualified_observation',(await one(`select count(*)=0 ok from (select ruleset_id,r1d_certification_run_id,observation_fingerprint,count(*) from retail.r1e_qualification_results where decision='QUALIFIED' and engine_version='r1e-v2.0.0' group by 1,2,3 having count(*)>1) x`)).ok);
  push('no_profit_authority',(await one(`select count(*)=0 ok from information_schema.columns where table_schema='retail' and table_name like 'r1e_%' and (column_name ilike '%profit%' or column_name ilike '%roi%' or column_name ilike '%margin%')`)).ok);
  push('no_purchase_authority',(await one(`select count(*)=0 ok from information_schema.columns where table_schema='retail' and table_name like 'r1e_%' and (column_name ilike '%purchase%' or column_name ilike '%checkout%' or column_name ilike '%capital%')`)).ok);

  const pass=g.every(x=>x.ok);
  console.log(JSON.stringify({suite:'R1E_V2_FREEZE',allPassed:pass,gates:g},null,2));
  await pool.end();
  if(!pass) process.exitCode=2;
}
main().catch(e=>{console.error(e);process.exitCode=1;});
