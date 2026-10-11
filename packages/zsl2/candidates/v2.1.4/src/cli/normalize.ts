import {readFile} from 'node:fs/promises';
import {pool} from '../repositories/db.js';
import {sha256Json,sha256Text} from '../core/hash.js';
import {initializeCheckpoints,normalizeResumable} from '../services/normalize.service.js';

const policyPath=process.env.ZSL2_POLICY_PATH??'./config/normalization-policy.json';
const raw=await readFile(policyPath,'utf8');
const policy=JSON.parse(raw) as {version:string;requiredCertifiedSources:string[];execution?:{defaultPageSize?:number;sourcePageSizes?:Record<string,number>}};
const packageSha=process.env.ZSL2_PACKAGE_SHA256;if(!packageSha||!/^[0-9a-f]{64}$/.test(packageSha))throw new Error('ZSL2_PACKAGE_SHA256_REQUIRED');
const actor=process.env.ZSL2_ACTOR_ID??'zsl2-normalizer';const requestedRun=process.argv[2];
const p=pool(),c=await p.connect();let run:string|undefined;
try{
 const lock=await c.query(`select pg_try_advisory_lock(hashtextextended('TCDS:ZSL2:NORMALIZE',0)) locked`);if(lock.rows[0]?.locked!==true)throw new Error('ZSL2_NORMALIZATION_ALREADY_RUNNING');
 await c.query(`select zsl.zsl2_assert_required_sources_certified($1::text[])`,[policy.requiredCertifiedSources]);
 if(requestedRun){
  const q=await c.query(`select normalization_run_id::text,state,policy_version,policy_sha256,package_sha256 from zsl.zsl2_normalization_runs where normalization_run_id=$1`,[requestedRun]);if(q.rowCount!==1)throw new Error('ZSL2_RESUME_RUN_NOT_FOUND');const x=q.rows[0];
  if(!['STARTED','RECONCILING'].includes(String(x.state)))throw new Error(`ZSL2_RESUME_INVALID_STATE:${x.state}`);if(String(x.policy_version)!==policy.version||String(x.policy_sha256)!==sha256Text(raw))throw new Error('ZSL2_RESUME_POLICY_MISMATCH');if(String(x.package_sha256)!==packageSha)throw new Error('ZSL2_RESUME_PACKAGE_MISMATCH');run=String(x.normalization_run_id);
  if(!(await c.query(`select zsl.zsl2_bindings_still_valid($1) valid`,[run])).rows[0]?.valid)throw new Error('ZSL2_RESUME_UPSTREAM_BINDING_INVALID');
 }else{
  const bindingPath=process.env.ZSL2_SOURCE_BINDINGS_PATH;if(!bindingPath)throw new Error('ZSL2_SOURCE_BINDINGS_PATH_REQUIRED_FOR_NEW_RUN');
  const bindingDoc=JSON.parse(await readFile(bindingPath,'utf8')) as {sources:Array<{source_key:string;release_id:string;release_key:string;ingest_run_id:string;certification_run_id:string;certification_created_at:string}>};
  const provided=[...bindingDoc.sources].sort((a,b)=>a.source_key.localeCompare(b.source_key));const expected=[...policy.requiredCertifiedSources].sort();if(JSON.stringify(provided.map(x=>x.source_key))!==JSON.stringify(expected))throw new Error('ZSL2_EXACT_SOURCE_BINDINGS_REQUIRED');
  const q=await c.query(`insert into zsl.zsl2_normalization_runs(policy_version,policy_sha256,package_sha256,git_sha,actor_id,state) values($1,$2,$3,$4,$5,'STARTED') returning normalization_run_id::text`,[policy.version,sha256Text(raw),packageSha,process.env.ZSL2_GIT_SHA??null,actor]);run=String(q.rows[0].normalization_run_id);
  for(const x of provided){
   const verify=await c.query(`select 1 from zsl.zsl2_current_source_certifications where source_key=$1 and release_id=$2 and ingest_run_id=$3 and certification_run_id=$4`,[x.source_key,x.release_id,x.ingest_run_id,x.certification_run_id]);if(verify.rowCount!==1)throw new Error(`ZSL2_EXPLICIT_BINDING_NOT_CURRENT_CERTIFIED:${x.source_key}`);
   await c.query(`insert into zsl.zsl2_source_bindings(normalization_run_id,source_key,release_id,release_key,ingest_run_id,certification_run_id,certification_created_at) values($1,$2,$3,$4,$5,$6,$7)`,[run,x.source_key,x.release_id,x.release_key,x.ingest_run_id,x.certification_run_id,x.certification_created_at]);
  }
  await initializeCheckpoints(c,run,policy.requiredCertifiedSources);
  const ss=await c.query(`select source_key,record_count::text,record_set_sha256 from zsl.zsl2_source_snapshots where normalization_run_id=$1 order by source_key`,[run]);const sourceSnapshotSha=sha256Json(ss.rows);await c.query(`update zsl.zsl2_normalization_runs set source_snapshot_sha256=$2 where normalization_run_id=$1`,[run,sourceSnapshotSha]);
 }
 await c.query(`update zsl.zsl2_normalization_runs set state='RECONCILING' where normalization_run_id=$1`,[run]);
 const pageConfig=policy.execution?.sourcePageSizes?{defaultPageSize:policy.execution?.defaultPageSize??5000,sourcePageSizes:policy.execution.sourcePageSizes}:{defaultPageSize:policy.execution?.defaultPageSize??5000};
 const result=await normalizeResumable(c,run,policy.requiredCertifiedSources,pageConfig);
 const cps=await c.query(`select source_key,status,records_processed::text,locations_processed::text,relationships_processed::text,lineage_processed::text,page_number::text,checkpoint_sha256 from zsl.zsl2_normalization_checkpoints where normalization_run_id=$1 order by source_key`,[run]);
 const complete=cps.rows.length===policy.requiredCertifiedSources.length&&cps.rows.every((x:Record<string,unknown>)=>x.status==='COMPLETE');if(!complete)throw new Error('ZSL2_CHECKPOINTS_INCOMPLETE');
 const fatal=BigInt(String((await c.query(`select count(*)::text n from zsl.zsl2_conflicts where normalization_run_id=$1 and severity='FATAL' and not resolved`,[run])).rows[0].n));if(fatal>0n)throw new Error(`FATAL_NORMALIZATION_CONFLICTS:${fatal}`);
 for(const source of policy.requiredCertifiedSources){if(!(await c.query(`select zsl.zsl2_source_snapshot_still_valid($1,$2) valid`,[run,source])).rows[0]?.valid)throw new Error(`ZSL2_SOURCE_SNAPSHOT_DRIFT:${source}`);}
 const evidence={mode:requestedRun?'RESUME':'NEW',result,checkpoints:cps.rows,sourceCount:policy.requiredCertifiedSources.length};await c.query(`update zsl.zsl2_normalization_runs set state='RECONCILED',completed_at=now(),evidence=$2::jsonb,evidence_sha256=$3 where normalization_run_id=$1`,[run,JSON.stringify(evidence),sha256Json(evidence)]);
 console.log(JSON.stringify({normalizationRunId:run,state:'RECONCILED',...result,checkpoints:cps.rows},null,2));
}catch(e){if(run){const msg=e instanceof Error?e.message:String(e);try{await c.query(`update zsl.zsl2_normalization_runs set state=case when state='RECONCILING' then 'STARTED' else state end,evidence=jsonb_build_object('last_error',$2,'recoverable',true,'resume_command','npm run normalize -- '||normalization_run_id::text),evidence_sha256=encode(digest(convert_to(jsonb_build_object('last_error',$2,'recoverable',true)::text,'UTF8'),'sha256'),'hex') where normalization_run_id=$1`,[run,msg.slice(0,4000)])}catch{}}throw e;
}finally{try{await c.query(`select pg_advisory_unlock(hashtextextended('TCDS:ZSL2:NORMALIZE',0))`)}catch{}c.release();await p.end();}
