import {pool} from '../repositories/db.js';
import {ZSL2_FORBIDDEN_OWNERSHIP} from '../core/domain-boundary.js';
const p=pool(),c=await p.connect();try{
 const schemas=['arb','retail','zsl1','zsl3','zsl4','zsl5','zsl6','pqp','cax','orl','warehouse','shipping'];const rows=[];
 for(const schema of schemas){const exists=(await c.query(`select exists(select 1 from pg_namespace where nspname=$1) e`,[schema])).rows[0]?.e;if(!exists){rows.push({schema,status:'ABSENT'});continue;}const q=await c.query(`select grantee,privilege_type,count(*)::int n from information_schema.role_table_grants where table_schema=$1 and grantee=any($2::text[]) and privilege_type in('INSERT','UPDATE','DELETE','TRUNCATE') group by grantee,privilege_type`,[schema,['zsl2_reader','zsl2_normalizer','zsl2_certifier','zsl2_runtime_tester','zsl2_r1b_bridge']]);rows.push({schema,status:q.rowCount===0?'DENIED':'VIOLATION',grants:q.rows});}
 const pass=rows.every(x=>x.status!=='VIOLATION');console.log(JSON.stringify({pass,forbiddenOwnership:ZSL2_FORBIDDEN_OWNERSHIP,schemas:rows},null,2));if(!pass)process.exitCode=2;
}finally{c.release();await p.end();}
