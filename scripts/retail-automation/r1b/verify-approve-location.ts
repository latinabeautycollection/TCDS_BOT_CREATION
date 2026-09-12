import { Pool } from 'pg';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [locationId,evidenceFile,verifierArg,approverArg]=process.argv.slice(2);
const verifier=verifierArg||process.env.R1B_VERIFIER;
const approver=approverArg||process.env.R1B_APPROVER;

if(!locationId||!evidenceFile||!verifier||!approver){
  throw new Error('usage: tsx verify-approve-location.ts <location_uuid> <evidence_file> <verifier> <approver>');
}

async function main(){
  const evidence=await readFile(evidenceFile);
  const hash=createHash('sha256').update(evidence).digest('hex');
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','user',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[approver]);

    const row=await c.query(`select * from retail.search_locations where id=$1 for update`,[locationId]);
    if(!row.rowCount) throw new Error('location not found');
    if(row.rows[0].location_status==='retired') throw new Error('retired location is terminal');

    if(row.rows[0].location_status==='draft' || row.rows[0].location_status==='suspended'){
      await c.query(
        `update retail.search_locations
            set location_status='verified',
                verification_method='evidence_file_sha256',
                verification_evidence_json=jsonb_build_object('file',$2),
                verification_evidence_hash=$3,
                verified_by=$4,
                verified_at=now()
          where id=$1`,
        [locationId,evidenceFile,hash,verifier]
      );
    }

    await c.query(
      `update retail.search_locations
          set location_status='approved',
              approved_by=$2,
              approved_at=now()
        where id=$1`,
      [locationId,approver]
    );

    await c.query('commit');
    console.log(JSON.stringify({event:'r1b_location_approved',locationId,evidenceSha256:hash},null,2));
  }catch(e){
    await c.query('rollback'); throw e;
  }finally{
    c.release(); await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
