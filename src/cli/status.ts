import {pool} from '../repositories/db.js';
const p=pool();const c=await p.connect();
try{
 const runs=await c.query(`select n.normalization_run_id,n.state,n.started_at,n.completed_at,c.status certification_status,c.created_at certified_at,
   zsl.zsl2_bindings_still_valid(n.normalization_run_id) bindings_still_valid
   from zsl.zsl2_normalization_runs n
   left join lateral(select * from zsl.zsl2_certification_runs x where x.normalization_run_id=n.normalization_run_id order by created_at desc,certification_run_id desc limit 1)c on true
   order by n.started_at desc limit 20`);
 const authority=await c.query(`select * from zsl.zsl2_current_authority`);
 console.table(runs.rows);console.log('CURRENT_AUTHORITY',authority.rows[0]??null);
}finally{c.release();await p.end()}
