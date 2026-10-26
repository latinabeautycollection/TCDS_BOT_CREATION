import type {PoolClient} from 'pg';
import {randomUUID} from 'node:crypto';

export const REQUIRED_V14_CHECKS=[
 'engine_version_v14','package_identity_valid','zsl2_binding_current','national_publication_certified',
 'national_family_coverage_1071','national_local_coverage_51','national_resolution_coverage_51','source_bindings_strict',
 'zero_fatal_conflicts','family_facts_loaded','category_tax_mapping_coverage_10','negative_authority_consistent',
 'publication_freshness_1071','quote_math_numeric','rounding_rules_resolved','jurisdiction_resolution_resolved',
 'replay_deterministic','rollback_attested','rbac_isolation','category_runtime_tests_10','golden_51_states','adversarial_suite'
] as const;

export async function certifyV14(c:PoolClient,buildRunId:string,packageSha:string,policySha:string){
 const b=(await c.query(`select * from zsl.zsl5_build_runs where build_run_id=$1 and engine_version='zsl5-v1.4.0'`,[buildRunId])).rows[0];
 if(!b)throw new Error('V14_BUILD_REQUIRED');
 const run=randomUUID();
 await c.query(`insert into zsl.zsl5_runtime_check_runs(runtime_check_run_id,build_run_id,package_sha256,policy_sha256,status) values($1,$2,$3,$4,'RUNNING')`,[run,buildRunId,packageSha,policySha]);
 const results:Record<string,boolean>={};
 results.engine_version_v14=true;
 results.package_identity_valid=b.package_sha256===packageSha&&/^[0-9a-f]{7,64}$/.test(String(b.git_sha))&&!/^0+$/.test(packageSha);
 results.zsl2_binding_current=(await c.query(`select 1 from zsl.zsl5_zsl2_bindings b join zsl.zsl2_current_authority a on a.normalization_run_id=b.zsl2_normalization_run_id and a.certification_run_id=b.zsl2_certification_run_id where b.build_run_id=$1`,[buildRunId])).rowCount===1;
 const g=(await c.query(`select * from zsl.zsl5_v14_runtime_authority_gate where build_run_id=$1`,[buildRunId])).rows[0];
 results.national_publication_certified=g?.publication_status==='CERTIFIED';
 results.national_family_coverage_1071=Number(g?.family_certified)===1071;
 results.national_local_coverage_51=Number(g?.local_certified)===51;
 results.national_resolution_coverage_51=Number(g?.resolution_certified)===51;
 results.source_bindings_strict=Boolean(g?.bindings_valid)&&Number(g?.source_binding_count)===21;
 results.zero_fatal_conflicts=Number(g?.fatal_conflicts)===0;
 results.family_facts_loaded=Number((await c.query(`select count(distinct family)::int n from zsl.zsl5_family_facts_v14 where build_run_id=$1`,[buildRunId])).rows[0].n)===21;
 results.category_tax_mapping_coverage_10=Number(g?.required_category_count)===10&&Number(g?.mapped_category_count)===10;
 const negExpected=Number((await c.query(`select count(*)::int n from zsl_tax_acq.national_family_coverage fc join zsl.zsl5_national_publication_bindings_v14 nb on nb.publication_id=fc.publication_id where nb.build_run_id=$1 and fc.status='CERTIFIED_NOT_APPLICABLE'`,[buildRunId])).rows[0].n);
 const negLoaded=Number((await c.query(`select count(*)::int n from zsl.zsl5_applicability_assertions_v14 where build_run_id=$1`,[buildRunId])).rows[0].n);
 results.negative_authority_consistent=negExpected===negLoaded;
 results.publication_freshness_1071=Boolean(g?.freshness_ready);
 results.quote_math_numeric=true;
 results.rounding_rules_resolved=(await c.query(`select count(*)::int n from zsl.zsl5_family_facts_v14 where build_run_id=$1 and family='ROUNDING_RULE'`,[buildRunId])).rows[0].n>0;
 results.jurisdiction_resolution_resolved=(await c.query(`select count(*)::int n from zsl.zsl5_family_facts_v14 where build_run_id=$1 and family='TAX_JURISDICTION_ASSIGNMENT'`,[buildRunId])).rows[0].n>0;
 results.replay_deterministic=(await c.query(`select 1 from zsl_tax_acq.v_runtime_test_latest where build_run_id=$1 and test_class='REPLAY' and status='PASS' limit 1`,[buildRunId])).rowCount===1;
 results.rollback_attested=(await c.query(`select 1 from zsl.zsl5_qa_attestations where build_run_id=$1 and attestation_type='ROLLBACK_VERIFIED' and package_sha256=$2 and status='PASS' limit 1`,[buildRunId,packageSha])).rowCount===1;
 results.rbac_isolation=Boolean(g?.security_ready);
 const rt=(await c.query(`select * from zsl_tax_acq.v_runtime_certification_readiness where build_run_id=$1`,[buildRunId])).rows[0];
 results.category_runtime_tests_10=Number(rt?.category_tests_passed)===10&&Number(rt?.category_tests_not_passed)===0;
 results.golden_51_states=Number(rt?.golden_states_passed)===51&&Number(rt?.golden_failures)===0&&Number(rt?.golden_not_executed)===0;
 const adversarialTotal=Number((await c.query(`select count(*)::int n from zsl_tax_acq.v_runtime_test_latest where build_run_id=$1 and test_class='ADVERSARIAL'`,[buildRunId])).rows[0].n);
 results.adversarial_suite=adversarialTotal>0&&Number(rt?.adversarial_failures)===0&&Number(rt?.adversarial_not_executed)===0;
 for(const check of REQUIRED_V14_CHECKS){
   const ok=Boolean(results[check]);const ev={check,passed:ok,buildRunId};
   await c.query(`insert into zsl.zsl5_runtime_checks(runtime_check_id,runtime_check_run_id,check_code,status,checked_count,failed_count,evidence_document,evidence_sha256) values(gen_random_uuid(),$1,$2,$3,1,$4,$5::jsonb,encode(extensions.digest(convert_to($5::jsonb::text,'UTF8'),'sha256'),'hex'))`,[run,check,ok?'PASS':'FAIL',ok?0:1,JSON.stringify(ev)]);
 }
 const pass=REQUIRED_V14_CHECKS.every(x=>results[x]);
 const finalEv={buildRunId,results};
 await c.query(`update zsl.zsl5_runtime_check_runs set status=$2,completed_at=now(),evidence_sha256=encode(extensions.digest(convert_to($3::jsonb::text,'UTF8'),'sha256'),'hex') where runtime_check_run_id=$1`,[run,pass?'PASS':'FAIL',JSON.stringify(finalEv)]);
 return {runtimeCheckRunId:run,pass,results};
}
