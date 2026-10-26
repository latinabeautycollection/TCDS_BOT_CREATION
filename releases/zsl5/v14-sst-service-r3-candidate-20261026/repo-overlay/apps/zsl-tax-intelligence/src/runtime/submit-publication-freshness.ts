import {readFile} from 'node:fs/promises';
import {pool} from '../core/db.js';
import {sha256} from '../core/hash.js';
import {TAX_FAMILIES} from '../core/types.js';

const arg=(n:string)=>{const i=process.argv.indexOf(n);return i>=0?process.argv[i+1]:undefined};
const publicationId=arg('--publication');const evidencePath=arg('--evidence');
if(!publicationId||!evidencePath)throw new Error('--publication UUID and --evidence file required');
const doc=JSON.parse(await readFile(evidencePath,'utf8'));
if(!Array.isArray(doc.attestations)||doc.attestations.length!==1071)throw new Error('FRESHNESS_ATTESTATION_DENOMINATOR_REQUIRED:1071');
const seen=new Set<string>();
for(const a of doc.attestations){
 const k=`${a.state_code}:${a.family}`;
 if(seen.has(k))throw new Error('DUPLICATE_FRESHNESS_CELL:'+k);seen.add(k);
 if(!TAX_FAMILIES.includes(a.family))throw new Error('UNKNOWN_FAMILY:'+a.family);
 if(a.status!=='PASS')throw new Error('NON_PASS_FRESHNESS:'+k);
 if(!/^https:\/\//.test(String(a.authority_url??''))||!/^[0-9a-f]{64}$/.test(String(a.evidence_sha256??'')))throw new Error('UNSEALED_FRESHNESS_EVIDENCE:'+k);
 if(!a.reviewed_at||!a.next_review_due||new Date(a.next_review_due)<=new Date(a.reviewed_at))throw new Error('INVALID_FRESHNESS_WINDOW:'+k);
}
const c=await pool.connect();
try{
 await c.query('BEGIN');await c.query(`select pg_advisory_xact_lock(hashtextextended($1,0))`,[`TCDS:ZSL1:TAX:FRESHNESS:${publicationId}`]);
 for(const a of doc.attestations){
  const ev={authority_url:a.authority_url,source_release_id:a.source_release_id??null,notes:a.notes??null};
  await c.query(`insert into zsl_tax_acq.publication_freshness_attestations(publication_id,state_code,family,status,reviewed_at,next_review_due,evidence,evidence_sha256,reviewed_by)
                 values($1,$2,$3,'PASS',$4,$5,$6::jsonb,$7,$8)
                 on conflict(publication_id,state_code,family) do nothing`,
    [publicationId,a.state_code,a.family,a.reviewed_at,a.next_review_due,JSON.stringify(ev),a.evidence_sha256,a.reviewed_by]);
 }
 const r=(await c.query(`select * from zsl_tax_acq.v_publication_freshness_readiness where publication_id=$1`,[publicationId])).rows[0];
 if(!r?.ready)throw new Error('PUBLICATION_FRESHNESS_NOT_READY:'+JSON.stringify(r));
 await c.query('COMMIT');console.log(JSON.stringify(r,null,2));
}catch(e){await c.query('ROLLBACK');throw e}finally{c.release();await pool.end()}
