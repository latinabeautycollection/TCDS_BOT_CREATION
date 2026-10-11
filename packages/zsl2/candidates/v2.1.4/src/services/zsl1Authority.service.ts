import type {PoolClient} from 'pg';
import {readFile} from 'node:fs/promises';
import {createHash,verify} from 'node:crypto';

const EXPECTED_ZSL1='8565bda4f631f56e8f9aa1db6982144182a7076027cc77811e9398bc5a29a43c';
const sha256=(b:Buffer|string)=>createHash('sha256').update(b).digest('hex');

export async function verifyAndRecordZsl1AuthorityDecision(c:PoolClient,runId:string){
 const decisionPath=process.env.ZSL2_ZSL1_AUTHORITY_DECISION_PATH;
 const signaturePath=process.env.ZSL2_ZSL1_AUTHORITY_SIGNATURE_PATH;
 const publicKeyPath=process.env.ZSL2_ZSL1_GOVERNANCE_PUBLIC_KEY_PATH;
 const pinned=process.env.ZSL2_ZSL1_GOVERNANCE_PUBLIC_KEY_SHA256?.toLowerCase();
 if(!decisionPath||!signaturePath||!publicKeyPath||!pinned||!/^[0-9a-f]{64}$/.test(pinned))throw new Error('ZSL2_ZSL1_SIGNED_DECISION_INPUTS_REQUIRED');
 const [payload,signature,publicKey]=await Promise.all([readFile(decisionPath),readFile(signaturePath),readFile(publicKeyPath)]);
 if(sha256(publicKey)!==pinned)throw new Error('ZSL2_ZSL1_PUBLIC_KEY_PIN_MISMATCH');
 if(!verify(null,payload,{key:publicKey,format:'pem'},signature))throw new Error('ZSL2_ZSL1_DECISION_SIGNATURE_INVALID');
 const d=JSON.parse(payload.toString('utf8')) as Record<string,unknown>;
 const requiredTrue=['all_required_releases_present','no_current_revocation','no_current_supersession_invalidation','faf6_certified'];
 if(String(d.evidenceType)!=='ZSL1_AUTHORITY_DECISION'||String(d.authority_model)!=='CERTIFIED_RELEASE_VIEW')throw new Error('ZSL2_ZSL1_DECISION_AUTHORITY_MODEL_INVALID');
 if(String(d.zsl1_package_sha)!==EXPECTED_ZSL1)throw new Error('ZSL2_ZSL1_DECISION_PACKAGE_SHA_MISMATCH');
 if(Number(d.governed_release_count)!==13)throw new Error('ZSL2_ZSL1_DECISION_RELEASE_COUNT_INVALID');
 if(String(d.all_current_certifications)!=='CERTIFIED'||requiredTrue.some(k=>d[k]!==true))throw new Error('ZSL2_ZSL1_DECISION_SEMANTICS_INVALID');
 if(String(d.signer_identity)!=='Anthony Malone')throw new Error('ZSL2_ZSL1_DECISION_SIGNER_INVALID');
 if(String(d.targetRunId)!==runId)throw new Error('ZSL2_ZSL1_DECISION_TARGET_RUN_MISMATCH');
 const popSha=String(d.certified_release_population_sha??'');
 if(!/^[0-9a-f]{64}$/.test(popSha))throw new Error('ZSL2_ZSL1_DECISION_POPULATION_SHA_INVALID');
 const live=await c.query(`select zsl.zsl2_zsl1_authority_population_sha_v214($1) sha,zsl.zsl2_zsl1_authority_release_count_v214($1) n`,[EXPECTED_ZSL1]);
 if(String(live.rows[0]?.sha)!==popSha||Number(live.rows[0]?.n)!==13)throw new Error('ZSL2_ZSL1_LIVE_AUTHORITY_POPULATION_MISMATCH');
 const checkedAt=new Date(String(d.checked_at??d.issuedAt??'')); if(Number.isNaN(checkedAt.getTime()))throw new Error('ZSL2_ZSL1_DECISION_CHECKED_AT_INVALID');
 const maxAgeMinutes=Number(process.env.ZSL2_ZSL1_DECISION_MAX_AGE_MINUTES??'1440'); if(Date.now()-checkedAt.getTime()>maxAgeMinutes*60_000)throw new Error('ZSL2_ZSL1_DECISION_STALE');
 const payloadSha=sha256(payload),sigSha=sha256(signature);
 await c.query(`insert into zsl.zsl2_zsl1_authority_decisions_v214(normalization_run_id,zsl1_package_sha256,authority_model,governed_release_count,certified_release_population_sha256,signer_identity,public_key_sha256,decision_payload_sha256,signature_sha256,checked_at,evidence)
 values($1,$2,'CERTIFIED_RELEASE_VIEW',13,$3,$4,$5,$6,$7,$8,$9::jsonb) on conflict(normalization_run_id,decision_payload_sha256) do nothing`,[runId,EXPECTED_ZSL1,popSha,String(d.signer_identity),pinned,payloadSha,sigSha,checkedAt.toISOString(),payload.toString('utf8')]);
 return {packageSha:EXPECTED_ZSL1,populationSha:popSha,releaseCount:13,signer:String(d.signer_identity),payloadSha,signatureSha:sigSha};
}
