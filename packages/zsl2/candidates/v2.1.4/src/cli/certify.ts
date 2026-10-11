import {readFile} from 'node:fs/promises';
import {pool} from '../repositories/db.js';
import {sha256Text} from '../core/hash.js';
import {buildCertificationEvidence} from '../services/certification.service.js';
import {verifyAndRecordZsl1AuthorityDecision} from '../services/zsl1Authority.service.js';

const mode=process.argv[2];const run=process.argv[3];const suppliedEval=process.argv[4];
if(!['prepare','finalize'].includes(mode??'')||!run)throw new Error('USAGE: certify.ts prepare <run> | finalize <run> <evaluation_id>');
const raw=await readFile(process.env.ZSL2_POLICY_PATH??'./config/normalization-policy.json','utf8');const policy=JSON.parse(raw);
const bindingsRaw=await readFile('./config/upstream-package-bindings.json','utf8');const bindingDoc=JSON.parse(bindingsRaw);
const pkg=process.env.ZSL2_PACKAGE_SHA256;if(!pkg||!/^[0-9a-f]{64}$/.test(pkg))throw new Error('ZSL2_PACKAGE_SHA256_REQUIRED');
const actor=process.env.ZSL2_ACTOR_ID??'zsl2-certifier';const p=pool(),c=await p.connect();
try{
 await c.query('begin');
 const nr=await c.query(`select state,package_sha256,policy_sha256 from zsl.zsl2_normalization_runs where normalization_run_id=$1`,[run]);if(nr.rowCount!==1)throw new Error('ZSL2_CERT_RUN_NOT_FOUND');if(nr.rows[0].state!=='RECONCILED')throw new Error('ZSL2_CERT_REQUIRES_RECONCILED');if(String(nr.rows[0].package_sha256)!==pkg)throw new Error('ZSL2_CERT_PACKAGE_SHA_MISMATCH');if(String(nr.rows[0].policy_sha256)!==sha256Text(raw))throw new Error('ZSL2_CERT_POLICY_SHA_MISMATCH');
 if(mode==='prepare'){
  const authority=await verifyAndRecordZsl1AuthorityDecision(c,run);
  const e=await c.query(`select zsl.zsl2_begin_evaluation_v214($1,$2,$3,$4)::text evaluation_id`,[run,pkg,sha256Text(raw),actor]);const evaluationId=String(e.rows[0].evaluation_id);
  const evidence=await buildCertificationEvidence(c,run,policy,String(bindingDoc?.ZSL1?.sha256??''),evaluationId);
  await c.query('commit');console.log(JSON.stringify({status:'PREPARED',evaluationId,authority,evidence,next:`npm run runtime:certify -- ${run} ${evaluationId} && npm run certify:finalize -- ${run} ${evaluationId}`},null,2));
 } else {
  if(!suppliedEval)throw new Error('EVALUATION_ID_REQUIRED');
  const checks=await c.query(`select check_name,passed,measured_value from zsl.zsl2_runtime_checks_v214 where normalization_run_id=$1 and evaluation_id=$2 order by check_name`,[run,suppliedEval]);
  const evidence={evaluationId:suppliedEval,checks:checks.rows};
  const q=await c.query(`select * from zsl.zsl2_finalize_certification_v214($1,$2,$3,$4,$5::jsonb)`,[run,suppliedEval,process.env.ZSL2_GIT_SHA??null,sha256Text(bindingsRaw),JSON.stringify(evidence)]);
  await c.query('commit');console.log(JSON.stringify({certificationRunId:q.rows[0].certification_run_id,status:q.rows[0].status,evaluationId:suppliedEval},null,2));
 }
}catch(e){try{await c.query('rollback')}catch{};throw e}finally{c.release();await p.end();}
