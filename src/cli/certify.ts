import {readFile} from 'node:fs/promises';
import {pool} from '../repositories/db.js';
import {sha256Text} from '../core/hash.js';
import {buildCertificationEvidence,sealEvidence} from '../services/certification.service.js';
const run=process.argv[2];if(!run)throw new Error('USAGE: certify <normalization_run_uuid>');
const raw=await readFile(process.env.ZSL2_POLICY_PATH??'./config/normalization-policy.json','utf8');
const policy=JSON.parse(raw);
const bindings=await readFile('./config/upstream-package-bindings.json','utf8');
const bindingDoc=JSON.parse(bindings);
const pkg=process.env.ZSL2_PACKAGE_SHA256;if(!pkg||!/^[0-9a-f]{64}$/.test(pkg))throw new Error('ZSL2_PACKAGE_SHA256_REQUIRED');
const p=pool();const c=await p.connect();
try{
 await c.query('begin');
 const evidence=await buildCertificationEvidence(c,run,policy,String(bindingDoc?.ZSL1?.sha256??''));
 const ok=Object.values(evidence.checks).every(Boolean);
 const q=await c.query(`insert into zsl.zsl2_certification_runs(normalization_run_id,engine_version,package_sha256,git_sha,policy_sha256,upstream_binding_sha256,status,evidence,evidence_sha256)
 values($1,'zsl2-v2.1.0',$2,$3,$4,$5,$6,$7::jsonb,$8) returning certification_run_id::text`,[run,pkg,process.env.ZSL2_GIT_SHA??null,sha256Text(raw),sha256Text(bindings),ok?'CERTIFIED':'FAILED',JSON.stringify(evidence),sealEvidence(evidence)]);
 await c.query('commit');
 console.log(JSON.stringify({status:ok?'CERTIFIED':'FAILED',certificationRunId:q.rows[0].certification_run_id,evidence},null,2));
}catch(e){await c.query('rollback');throw e}finally{c.release();await p.end()}
