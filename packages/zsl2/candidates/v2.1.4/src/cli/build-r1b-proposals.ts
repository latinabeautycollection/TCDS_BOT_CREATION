import {pool} from '../repositories/db.js';import {sha256Json} from '../core/hash.js';
const p=pool();const c=await p.connect();try{
 const rows=await c.query(`select * from zsl.r1b_location_candidates where r1b_eligible_location_type is not null`);let n=0;
 for(const x of rows.rows){
   const code=x.r1b_eligible_location_type==='state'?`ZSL_STATE_${x.state_code}`:x.r1b_eligible_location_type==='metro'?`ZSL_CBSA_${x.cbsa_code}`:`ZSL_ZIP_${x.postal_code}`;
   const doc={zsl_location_id:x.zsl_location_id,normalization_run_id:x.normalization_run_id,certification_run_id:x.certification_run_id,location_code:code,location_type:x.r1b_eligible_location_type,country_code:x.country_code,state_code:x.state_code,metro_name:x.metro_name,postal_code:x.postal_code,display_name:x.display_name,latitude:x.latitude,longitude:x.longitude,verification_method:'ZSL2_EFFECTIVE_CERTIFIED_CANONICAL_GEOGRAPHY',zsl_identity_sha256:x.zsl_identity_sha256};
   await c.query(`insert into zsl.r1b_location_sync_proposals(zsl_location_id,proposed_r1b_location_type,proposed_location_code,proposal_document,proposal_sha256,normalization_run_id,certification_run_id,zsl_identity_sha256)
   values($1,$2,$3,$4::jsonb,$5,$6,$7,$8) on conflict do nothing`,[x.zsl_location_id,x.r1b_eligible_location_type,code,JSON.stringify(doc),sha256Json(doc),x.normalization_run_id,x.certification_run_id,x.zsl_identity_sha256]);n++;
 }
 console.log(JSON.stringify({proposalsConsidered:n,note:'Generated only from effective certified ZSL2 authority; no retail.search_locations rows mutated.'}));
}finally{c.release();await p.end()}
