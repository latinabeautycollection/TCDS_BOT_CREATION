import { Pool } from 'pg';
const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [rulesetId]=process.argv.slice(2);

if(!rulesetId){
  throw new Error('usage: tsx adversarial-tests-v21.ts <ruleset_uuid>');
}

async function main(){
  const g:any[]=[];
  const gate=(name:string,ok:boolean,detail:any={})=>g.push({name,ok,detail});
  const one=async(sql:string,args:any[]=[])=>(await pool.query(sql,args)).rows[0];

  gate('v21_state',
    (await one(`select exists(
      select 1 from retail.r1e_v21_state
      where singleton and hardening_version='2.1.0'
    ) ok`)).ok);

  gate('r1d_binding_current',
    (await one(`select retail.r1e_r1d_binding_is_current() ok`)).ok);

  gate('legacy_v1_worker_evaluator_revoked',
    (await one(`select not has_function_privilege(
      'retail_r1e_worker',
      'retail.r1e_evaluate_capture(uuid,uuid,uuid,text,text)',
      'EXECUTE'
    ) ok`)).ok);

  gate('legacy_v2_worker_evaluator_revoked',
    (await one(`select not has_function_privilege(
      'retail_r1e_worker',
      'retail.r1e_evaluate_capture_v2(uuid,uuid,uuid,text,text)',
      'EXECUTE'
    ) ok`)).ok);

  gate('legacy_v1_bind_revoked',
    (await one(`select not has_function_privilege(
      'retail_r1e_certifier',
      'retail.r1e_bind_r1d_certification(uuid,uuid,text,text)',
      'EXECUTE'
    ) ok`)).ok);

  gate('legacy_v1_ruleset_cert_revoked',
    (await one(`select not has_function_privilege(
      'retail_r1e_certifier',
      'retail.r1e_certify_ruleset(uuid,jsonb,text)',
      'EXECUTE'
    ) ok`)).ok);

  gate('v21_evaluator_granted',
    (await one(`select has_function_privilege(
      'retail_r1e_worker',
      'retail.r1e_evaluate_capture_v21(uuid,uuid,uuid,text,text,boolean)',
      'EXECUTE'
    ) ok`)).ok);

  gate('direct_r1a_revision_authority',
    (await one(`select to_regprocedure(
      'retail.r1e_r1a_revision_identity_document(uuid,text)'
    ) is not null ok`)).ok);

  gate('r1a_revision_hash_verification',
    (await one(`select pg_get_functiondef(
      'retail.r1e_r1a_revision_identity_document(uuid,text)'::regprocedure
    ) like '%r1a_revision_business_document%' ok`)).ok);

  gate('search_terms_separated',
    (await one(`select pg_get_functiondef(
      'retail.r1e_r1a_revision_identity_document(uuid,text)'::regprocedure
    ) like '%required_identity_terms%'
    and pg_get_functiondef(
      'retail.r1e_r1a_revision_identity_document(uuid,text)'::regprocedure
    ) like '%search_expansion_terms%' ok`)).ok);

  gate('capacity_normalization_256gb',
    (await one(`select retail.r1e_normalize_capacity('256 GB')='256gb' ok`)).ok);

  gate('capacity_normalization_1tb',
    (await one(`select retail.r1e_normalize_capacity('1 TB')='1000gb' ok`)).ok);

  gate('platform_alias_ps5',
    (await one(`select retail.r1e_normalize_platform('PS5')='playstation 5' ok`)).ok);

  gate('safe_uuid_malformed',
    (await one(`select retail.r1e_try_uuid('not-a-uuid') is null ok`)).ok);

  gate('ambiguous_lineage_function_present',
    (await one(`select pg_get_functiondef(
      'retail.r1e_resolve_attempt_for_capture(uuid)'::regprocedure
    ) like '%v_count<>1%' ok`)).ok);

  gate('collection_platform_check_present',
    (await one(`select pg_get_functiondef(
      'retail.r1e_resolve_attempt_for_capture(uuid)'::regprocedure
    ) like '%cr.platform_id=cap.platform_id%' ok`)).ok);

  gate('raw_payload_not_in_observation_identity',
    (await one(`select pg_get_functiondef(
      'retail.r1e_observation_document_v21(retail.raw_product_captures,retail.search_job_compilations,retail.retail_products)'::regprocedure
    ) not like '%raw_payload_hash%' ok`)).ok);

  gate('raw_payload_retained_in_evidence',
    (await one(`select pg_get_functiondef(
      'retail.r1e_evaluate_capture_v21(uuid,uuid,uuid,text,text,boolean)'::regprocedure
    ) like '%raw_payload_hash%' ok`)).ok);

  gate('certification_fixture_excluded_downstream',
    (await one(`select pg_get_viewdef(
      'retail.r1e_effective_qualified_products'::regclass,true
    ) like '%certification_fixture = false%' ok`)).ok);

  gate('currentness_requires_v21',
    (await one(`select pg_get_functiondef(
      'retail.r1e_latest_certification_is_current(uuid)'::regprocedure
    ) like '%r1e-v2.1.0%' ok`)).ok);

  gate('result_currentness_requires_v21',
    (await one(`select pg_get_functiondef(
      'retail.r1e_result_is_current(uuid)'::regprocedure
    ) like '%r1e-v2.1.0%' ok`)).ok);

  gate('policy_floor_immutable_versioned',
    (await one(`select count(*)=1 ok
      from retail.r1e_certification_policies
      where certification_status='certified'
        and policy_sha256=retail.r1e_sha256_jsonb(policy_json)
    `)).ok);

  gate('e2e_fixture_authority_exists',
    (await one(`select to_regclass(
      'retail.r1e_e2e_qa_fixtures'
    ) is not null ok`)).ok);

  gate('duplicate_race_fixture_authority_exists',
    (await one(`select to_regclass(
      'retail.r1e_duplicate_race_fixtures'
    ) is not null ok`)).ok);

  gate('qualified_observation_unique_index',
    (await one(`select exists(
      select 1 from pg_indexes
      where schemaname='retail'
        and indexname='uq_r1e_v2_one_qualified_observation'
    ) ok`)).ok);

  gate('ruleset_current',
    (await one(`select exists(
      select 1 from retail.r1e_match_rulesets
      where id=$1
        and certification_status='certified'
        and rules_sha256=retail.r1e_sha256_jsonb(rules_json)
    ) ok`,[rulesetId])).ok);

  gate('no_duplicate_v21_qualified_observation',
    (await one(`select count(*)=0 ok
      from (
        select ruleset_id,r1d_certification_run_id,
               observation_fingerprint,count(*)
        from retail.r1e_qualification_results
        where decision='QUALIFIED'
          and engine_version='r1e-v2.1.0'
        group by 1,2,3
        having count(*)>1
      ) x
    `)).ok);

  gate('v21_evidence_hashes_reproduce',
    (await one(`select count(*)=0 ok
      from retail.r1e_qualification_results
      where engine_version='r1e-v2.1.0'
        and evidence_sha256<>
          retail.r1e_sha256_jsonb(evidence_json)
    `)).ok);

  gate('v21_attempt_evidence_hashes_reproduce',
    (await one(`select count(*)=0 ok
      from retail.r1e_qualification_results
      where engine_version='r1e-v2.1.0'
        and r1d_attempt_evidence_sha256<>
          retail.r1e_sha256_jsonb(r1d_attempt_evidence_json)
    `)).ok);

  gate('lineage_anomaly_view_exists',
    (await one(`select to_regclass(
      'retail.r1e_lineage_anomalies'
    ) is not null ok`)).ok);

  gate('no_profit_authority',
    (await one(`select count(*)=0 ok
      from information_schema.columns
      where table_schema='retail'
        and table_name like 'r1e_%'
        and (
          column_name ilike '%profit%'
          or column_name ilike '%margin%'
          or column_name ilike '%roi%'
        )
    `)).ok);

  gate('no_purchase_checkout_capital_authority',
    (await one(`select count(*)=0 ok
      from information_schema.columns
      where table_schema='retail'
        and table_name like 'r1e_%'
        and (
          column_name ilike '%purchase_authorization%'
          or column_name ilike '%checkout_authorization%'
          or column_name ilike '%capital_allocation%'
        )
    `)).ok);

  const pass=g.every(x=>x.ok);
  console.log(JSON.stringify({
    suite:'R1E_V2_1_FINAL_FREEZE',
    allPassed:pass,
    passed:g.filter(x=>x.ok).length,
    failed:g.filter(x=>!x.ok).length,
    gates:g
  },null,2));

  await pool.end();
  if(!pass) process.exitCode=2;
}

main().catch(e=>{console.error(e);process.exitCode=1;});
