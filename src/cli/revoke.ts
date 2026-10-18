import {pool} from '../repositories/db.js';import {sha256Json} from '../core/hash.js';
const run=process.argv[2],cert=process.argv[3],reason=process.argv.slice(4).join(' ')||'MANUAL_REVOCATION';if(!run||!cert)throw new Error('USAGE: revoke <normalization_run_uuid> <certification_run_uuid> [reason]');
const p=pool(),c=await p.connect();try{const ev={reason,actor:process.env.ZSL2_ACTOR_ID??'zsl2-certifier'};await c.query(`insert into zsl.zsl2_authority_events(normalization_run_id,certification_run_id,event_type,reason,evidence,evidence_sha256)
 values($1,$2,'REVOKED',$3,$4::jsonb,$5)`,[run,cert,reason,JSON.stringify(ev),sha256Json(ev)]);console.log(JSON.stringify({status:'REVOKED',reason}));}finally{c.release();await p.end()}
