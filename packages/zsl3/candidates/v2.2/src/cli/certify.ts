import{pool,tx,advisory}from'../repositories/db.js';import{loadPolicies}from'../core/config.js';import{sha256Canonical}from'../core/hash.js';
const run=process.argv[2];if(!run)throw new Error('usage: certify <build_run_id>');const p=loadPolicies();
await tx(async c=>{
 await advisory(c,'TCDS:ZSL3:CERTIFY');const b=(await c.query<any>('SELECT * FROM zsl.zsl3_build_runs WHERE build_run_id=$1',[run])).rows[0];if(!b)throw new Error('ZSL3_BUILD_NOT_FOUND');
 const rc=(await c.query<any>(`SELECT * FROM zsl.zsl3_runtime_check_runs WHERE build_run_id=$1 AND status='PASS' ORDER BY completed_at DESC NULLS LAST,started_at DESC LIMIT 1`,[run])).rows[0];
 if(!rc)throw new Error('ZSL3_PASSING_RUNTIME_CHECK_RUN_REQUIRED');
 const ev={buildRunId:run,runtimeCheckRunId:rc.runtime_check_run_id,requiredChecks:p.certification.requiredChecks,featureRegistrySha256:b.feature_registry_sha256,certificationPolicySha256:b.certification_policy_sha256};
 await c.query(`INSERT INTO zsl.zsl3_certification_runs(
   build_run_id,runtime_check_run_id,status,engine_version,package_sha256,git_sha,source_manifest_sha256,migration_manifest_sha256,dependency_tree_sha256,
   source_policy_sha256,feature_policy_sha256,confidence_policy_sha256,freshness_policy_sha256,naics_policy_sha256,certification_policy_sha256,feature_registry_sha256,
   evidence,evidence_sha256,certifier_actor)
   VALUES($1,$2,'CERTIFIED','zsl3-v2.2.0',$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15::jsonb,$16,$17)`,
 [run,rc.runtime_check_run_id,b.package_sha256,b.git_sha,b.source_manifest_sha256,b.migration_manifest_sha256,b.dependency_tree_sha256,
  b.source_policy_sha256,b.feature_policy_sha256,b.confidence_policy_sha256,b.freshness_policy_sha256,b.naics_policy_sha256,
  b.certification_policy_sha256,b.feature_registry_sha256,JSON.stringify(ev),sha256Canonical(ev),process.env.ZSL3_CERTIFIER_ACTOR??'zsl3-certifier']);
});await pool.end();
