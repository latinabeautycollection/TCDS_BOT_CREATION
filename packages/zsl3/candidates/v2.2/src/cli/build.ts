import{pool,tx,advisory}from'../repositories/db.js';import{loadPolicies}from'../core/config.js';
import{bindSources}from'../bindings/source-binding.service.js';import{populateAcsMetadata}from'../metadata/acs-metadata.service.js';
import{normalizeAcs}from'../normalizers/acs.js';import{normalizeBea}from'../normalizers/bea.js';import{normalizeBusiness}from'../normalizers/business.js';
import{validateBuild}from'../validation/build-validation.service.js';import{deriveFeatures}from'../features/feature-engine.js';
import{buildSnapshots}from'../snapshots/snapshot.service.js';import{runChecks}from'../certification/certification.service.js';import{sha256Canonical}from'../core/hash.js';

const p=loadPolicies();const packageSha=process.env.ZSL3_PACKAGE_SHA256??'',gitSha=process.env.ZSL3_GIT_SHA??'';
const sourceManifest=process.env.ZSL3_SOURCE_MANIFEST_SHA256??'',migrationManifest=process.env.ZSL3_MIGRATION_MANIFEST_SHA256??'';
const dependencyTree=process.env.ZSL3_DEPENDENCY_TREE_SHA256??'',featureRegistry=sha256Canonical(p.feature.derivedDefinitions);
for(const [k,v]of Object.entries({packageSha,sourceManifest,migrationManifest,dependencyTree,featureRegistry}))if(!/^[0-9a-f]{64}$/.test(String(v)))throw new Error(`ZSL3_${k.toUpperCase()}_SHA_REQUIRED`);
if(!gitSha)throw new Error('ZSL3_GIT_SHA_REQUIRED');
const zsl2=(await pool.query<any>('SELECT * FROM zsl.zsl2_current_authority LIMIT 1')).rows[0];if(!zsl2)throw new Error('ZSL3_ZSL2_AUTHORITY_REQUIRED');
const created=await pool.query<any>(`INSERT INTO zsl.zsl3_build_runs(
 engine_version,package_sha256,git_sha,source_policy_sha256,feature_policy_sha256,confidence_policy_sha256,freshness_policy_sha256,naics_policy_sha256,
 certification_policy_sha256,source_manifest_sha256,migration_manifest_sha256,feature_registry_sha256,dependency_tree_sha256,
 zsl2_normalization_run_id,zsl2_certification_run_id,state)
 VALUES('zsl3-v2.2.0',$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,'CREATED') RETURNING build_run_id::text`,
 [packageSha,gitSha,p.hashes.source,p.hashes.feature,p.hashes.confidence,p.hashes.freshness,p.hashes.naics,p.hashes.certification,
  sourceManifest,migrationManifest,featureRegistry,dependencyTree,zsl2.normalization_run_id,zsl2.certification_run_id]);
const run=created.rows[0].build_run_id;
try{
 await tx(async c=>{
  await advisory(c,'TCDS:ZSL3:BUILD');await c.query(`SELECT zsl.zsl3_transition_build($1,'BINDING')`,[run]);
  await bindSources(c,run,p);await populateAcsMetadata(c,run,p.feature);
  await c.query(`SELECT zsl.zsl3_transition_build($1,'NORMALIZING')`,[run]);await normalizeAcs(c,run,p.feature);await normalizeBea(c,run);await normalizeBusiness(c,run,p.naics);
  await c.query(`SELECT zsl.zsl3_transition_build($1,'VALIDATING')`,[run]);await validateBuild(c,run,p);
  await c.query(`SELECT zsl.zsl3_transition_build($1,'DERIVING')`,[run]);await deriveFeatures(c,run,p.feature);
  await c.query(`SELECT zsl.zsl3_transition_build($1,'SNAPSHOTTING')`,[run]);await buildSnapshots(c,run,p,p.hashes.feature);
  await c.query(`SELECT zsl.zsl3_transition_build($1,'REPLAYING')`,[run]);const runtimeCheckRunId=await runChecks(c,run,p);
  await c.query(`SELECT zsl.zsl3_transition_build($1,'RECONCILED')`,[run]);console.log(JSON.stringify({buildRunId:run,runtimeCheckRunId,state:'RECONCILED'}));
 });
}catch(e:any){
 const ev={message:String(e?.message??e),stage:'BUILD'};
 await pool.query(`UPDATE zsl.zsl3_build_runs SET state='FAILED',completed_at=now(),failure_stage='BUILD',failure_class=$2,failure_error_redacted=$3,failure_evidence=$4::jsonb,failure_evidence_sha256=$5 WHERE build_run_id=$1`,
 [run,e?.name??'Error',String(e?.message??e).replace(/(key|token|password)=\S+/ig,'$1=[REDACTED]'),JSON.stringify(ev),sha256Canonical(ev)]);
 throw e;
}finally{await pool.end()}
