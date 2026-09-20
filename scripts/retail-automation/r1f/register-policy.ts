import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [file,codeArg,versionArg,actorArg]=process.argv.slice(2);
const code=codeArg||'r1f_search_intelligence';
const version=versionArg||'2';
const actor=actorArg||process.env.R1F_CERTIFIER||'R1F Policy Authority';

if(!file){
  throw new Error('usage: tsx register-policy.ts <policy.json> [code] [version] [actor]');
}

async function main(){
  const policy=JSON.parse(await readFile(file,'utf8'));
  const run=await startPersistentRun(
    pool,'RETAIL_R1F_POLICY_REGISTER','user',actor,actor,
    'retail.r1f_intelligence_policies'
  );
  const c=await pool.connect();
  try{
    await c.query('begin');
    const r=await c.query(`
      insert into retail.r1f_intelligence_policies(
        policy_code,policy_version,policy_json,policy_sha256,
        certification_status,created_by
      ) values(
        $1,$2,$3::jsonb,repeat('0',64),'draft',$4
      )
      returning id,policy_sha256
    `,[code,version,JSON.stringify(policy),actor]);

    await c.query(`
      select retail.r1f_certify_policy($1,$2,$3,$4)
    `,[r.rows[0].id,run.runId,run.correlationId,actor]);

    await c.query('commit');
    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:1,succeeded:1,failed:0}
    );

    console.log(JSON.stringify({
      event:'r1f_policy_certified',
      policyId:r.rows[0].id,
      policySha256:r.rows[0].policy_sha256,
      processRunId:run.runId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(
      pool,run.runId,'FAILED',
      {seen:1,succeeded:0,failed:1},e
    );
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}

main().catch(e=>{console.error(e);process.exitCode=1;});
