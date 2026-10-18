import {readFile} from 'node:fs/promises';
import {pool} from '../repositories/db.js';
import {sha256Text} from '../core/hash.js';
import {normalizeAll} from '../services/normalize.service.js';

const policyPath=process.env.ZSL2_POLICY_PATH??'./config/normalization-policy.json';
const raw=await readFile(policyPath,'utf8');
const policy=JSON.parse(raw) as {version:string;requiredCertifiedSources:string[]};
const packageSha=process.env.ZSL2_PACKAGE_SHA256;
if(!packageSha||!/^[0-9a-f]{64}$/.test(packageSha))throw new Error('ZSL2_PACKAGE_SHA256_REQUIRED');
const actor=process.env.ZSL2_ACTOR_ID??'zsl2-normalizer';
const p=pool();const c=await p.connect();
let run:string|undefined;
try{
  const lock=await c.query(`select pg_try_advisory_lock(hashtextextended('TCDS:ZSL2:NORMALIZE',0)) locked`);
  if(lock.rows[0]?.locked!==true)throw new Error('ZSL2_NORMALIZATION_ALREADY_RUNNING');
  await c.query(`select zsl.zsl2_assert_required_sources_certified($1::text[])`,[policy.requiredCertifiedSources]);
  const q=await c.query(`insert into zsl.zsl2_normalization_runs(policy_version,policy_sha256,package_sha256,git_sha,actor_id,state)
    values($1,$2,$3,$4,$5,'STARTED') returning normalization_run_id::text`,[policy.version,sha256Text(raw),packageSha,process.env.ZSL2_GIT_SHA??null,actor]);
  run=String(q.rows[0].normalization_run_id);
  for(const source of policy.requiredCertifiedSources){
    const b=await c.query(`select source_key,release_id,release_key,ingest_run_id,certification_run_id,created_at
      from zsl.zsl2_current_source_certifications where source_key=$1
      order by source_year desc nulls last,source_quarter desc nulls last,discovered_at desc,created_at desc limit 1`,[source]);
    if(b.rowCount!==1)throw new Error(`MISSING_SOURCE:${source}`);
    const x=b.rows[0];
    await c.query(`insert into zsl.zsl2_source_bindings(normalization_run_id,source_key,release_id,release_key,ingest_run_id,certification_run_id,certification_created_at)
      values($1,$2,$3,$4,$5,$6,$7)`,[run,x.source_key,x.release_id,x.release_key,x.ingest_run_id,x.certification_run_id,x.created_at]);
  }
  await c.query('begin');
  const result=await normalizeAll(c,run,policy.requiredCertifiedSources);
  const fatal=Number((await c.query(`select count(*) n from zsl.zsl2_conflicts where normalization_run_id=$1 and severity='FATAL' and not resolved`,[run])).rows[0].n);
  if(fatal>0)throw new Error(`FATAL_NORMALIZATION_CONFLICTS:${fatal}`);
  const evidence={result,sourceCount:policy.requiredCertifiedSources.length};
  await c.query(`update zsl.zsl2_normalization_runs set state='RECONCILED',completed_at=now(),evidence=$2::jsonb,evidence_sha256=$3 where normalization_run_id=$1`,[run,JSON.stringify(evidence),sha256Text(JSON.stringify(evidence))]);
  await c.query('commit');
  console.log(JSON.stringify({normalizationRunId:run,...result},null,2));
}catch(e){
  try{await c.query('rollback')}catch{}
  if(run){
    const msg=e instanceof Error?e.message:String(e);
    await c.query(`update zsl.zsl2_normalization_runs set state='FAILED',completed_at=now(),evidence=jsonb_build_object('error',$2),evidence_sha256=encode(digest(convert_to(jsonb_build_object('error',$2)::text,'UTF8'),'sha256'),'hex') where normalization_run_id=$1`,[run,msg.slice(0,4000)]);
  }
  throw e;
}finally{
  try{await c.query(`select pg_advisory_unlock(hashtextextended('TCDS:ZSL2:NORMALIZE',0))`)}catch{}
  c.release();await p.end();
}
