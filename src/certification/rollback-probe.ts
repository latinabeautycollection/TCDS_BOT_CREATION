import type{PoolClient}from'pg';import{randomUUID}from'node:crypto';import{sha256Canonical}from'../core/hash.js';

/**
 * Proves the database activation and revocation path without retaining a test
 * authority. The fixture is scoped to a savepoint and the authority baseline
 * must be identical after rollback before PASS evidence is persisted.
 */
export async function verifyRollback(c:PoolClient,run:string):Promise<void>{
 const b=(await c.query<any>(`SELECT * FROM zsl.zsl3_build_runs WHERE build_run_id=$1`,[run])).rows[0];if(!b)throw new Error('ZSL3_BUILD_NOT_FOUND');
 const baseline=(await c.query<any>(`SELECT build_run_id::text,certification_run_id::text,authority_event_id::text FROM zsl.zsl3_authority_state WHERE singleton`)).rows[0]??{};
 const checkRun=randomUUID(),certRun=randomUUID(),fixture={kind:'ZSL3_ROLLBACK_FIXTURE',isolationOnly:true,buildRunId:run};const fixtureSha=sha256Canonical(fixture);
 let activated:string|null=null,revoked:string|null=null;
 await c.query('SAVEPOINT zsl3_rollback_probe');
 try{
  // The certification guard requires RECONCILED. This transition is rolled
  // back with the fixture, returning the real build to REPLAYING.
  await c.query(`SELECT zsl.zsl3_transition_build($1,'RECONCILED')`,[run]);
  await c.query(`INSERT INTO zsl.zsl3_runtime_check_runs(runtime_check_run_id,build_run_id,package_sha256,policy_sha256,status,completed_at,evidence,evidence_sha256) VALUES($1,$2,$3,$4,'PASS',now(),$5::jsonb,$6)`,[checkRun,run,b.package_sha256,b.certification_policy_sha256,JSON.stringify(fixture),fixtureSha]);
  await c.query(`INSERT INTO zsl.zsl3_runtime_checks(runtime_check_run_id,build_run_id,check_code,status,checked_count,failed_count,expected_value,actual_value,evidence,evidence_sha256) SELECT $1,$2,code,'PASS',1,0,'{}'::jsonb,'{}'::jsonb,$3::jsonb,$4 FROM unnest(zsl.zsl3_required_check_codes()) code`,[checkRun,run,JSON.stringify(fixture),fixtureSha]);
  const certEvidence={...fixture,runtimeCheckRunId:checkRun};
  await c.query(`INSERT INTO zsl.zsl3_certification_runs(certification_run_id,build_run_id,runtime_check_run_id,status,engine_version,package_sha256,git_sha,source_manifest_sha256,migration_manifest_sha256,dependency_tree_sha256,source_policy_sha256,feature_policy_sha256,confidence_policy_sha256,freshness_policy_sha256,naics_policy_sha256,certification_policy_sha256,feature_registry_sha256,evidence,evidence_sha256,certifier_actor) VALUES($1,$2,$3,'CERTIFIED','zsl3-v2.2.0',$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16::jsonb,$17,'zsl3-rollback-probe')`,[certRun,run,checkRun,b.package_sha256,b.git_sha,b.source_manifest_sha256,b.migration_manifest_sha256,b.dependency_tree_sha256,b.source_policy_sha256,b.feature_policy_sha256,b.confidence_policy_sha256,b.freshness_policy_sha256,b.naics_policy_sha256,b.certification_policy_sha256,b.feature_registry_sha256,JSON.stringify(certEvidence),sha256Canonical(certEvidence)]);
  activated=String((await c.query<any>(`SELECT zsl.zsl3_activate($1,$2,'zsl3-rollback-probe',$3::jsonb) id`,[run,certRun,JSON.stringify(fixture)])).rows[0].id);
  revoked=String((await c.query<any>(`SELECT zsl.zsl3_revoke_active('zsl3-rollback-probe',$1::jsonb) id`,[JSON.stringify(fixture)])).rows[0].id);
  const revokedState=(await c.query<any>(`SELECT build_run_id::text,certification_run_id::text FROM zsl.zsl3_authority_state WHERE singleton`)).rows[0];
  if(revokedState?.build_run_id!==null||revokedState?.certification_run_id!==null)throw new Error('ZSL3_ROLLBACK_FIXTURE_REVOKE_INCOMPLETE');
  await c.query('ROLLBACK TO SAVEPOINT zsl3_rollback_probe');
 }catch(e){await c.query('ROLLBACK TO SAVEPOINT zsl3_rollback_probe');throw e}
 const restored=(await c.query<any>(`SELECT build_run_id::text,certification_run_id::text,authority_event_id::text FROM zsl.zsl3_authority_state WHERE singleton`)).rows[0]??{};
 const same=String(baseline.build_run_id??'')===String(restored.build_run_id??'')&&String(baseline.certification_run_id??'')===String(restored.certification_run_id??'')&&String(baseline.authority_event_id??'')===String(restored.authority_event_id??'');
 const residual=Number((await c.query<any>(`SELECT (SELECT count(*) FROM zsl.zsl3_runtime_check_runs WHERE runtime_check_run_id=$1)+(SELECT count(*) FROM zsl.zsl3_certification_runs WHERE certification_run_id=$2)+(SELECT count(*) FROM zsl.zsl3_authority_events WHERE certification_run_id=$2) n`,[checkRun,certRun])).rows[0].n);
 if(!same||residual!==0)throw new Error(`ZSL3_ROLLBACK_PROBE_NOT_RESTORED:baseline=${JSON.stringify(baseline)}:restored=${JSON.stringify(restored)}:residual=${residual}`);
 const evidence={method:'SAVEPOINT_ACTIVATE_REVOKE_ROLLBACK',buildRunId:run,fixtureRuntimeCheckRunId:checkRun,fixtureCertificationRunId:certRun,activationEventId:activated,revocationEventId:revoked,baseline,restored,residualRows:residual,verifiedAt:new Date().toISOString()};
 await c.query(`INSERT INTO zsl.zsl3_qa_evidence(build_run_id,evidence_code,status,evidence,evidence_sha256,actor) VALUES($1,'ROLLBACK_VERIFIED','PASS',$2::jsonb,$3,'zsl3-rollback-probe')`,[run,JSON.stringify(evidence),sha256Canonical(evidence)]);
}
