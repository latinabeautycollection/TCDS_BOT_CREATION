import {pool} from '../repositories/db.js';import {sha256Json} from '../core/hash.js';
const run=process.argv[2],cert=process.argv[3];if(!run||!cert)throw new Error('USAGE: activate <normalization_run_uuid> <certification_run_uuid>');
const p=pool(),c=await p.connect();try{const ev={reason:'EXPLICIT_PRODUCTION_AUTHORITY_ACTIVATION',actor:process.env.ZSL2_ACTOR_ID??'zsl2-certifier'};const q=await c.query(`insert into zsl.zsl2_authority_events(normalization_run_id,certification_run_id,event_type,reason,evidence,evidence_sha256)
 values($1,$2,'ACTIVATED',$3,$4::jsonb,$5) returning authority_event_id::text`,[run,cert,ev.reason,JSON.stringify(ev),sha256Json(ev)]);console.log(JSON.stringify({authorityEventId:q.rows[0].authority_event_id,status:'ACTIVATED'}));}finally{c.release();await p.end()}
