import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [rulesFile,codeArg,versionArg,actorArg]=process.argv.slice(2);
const code=codeArg||'returned_product_match';
const version=versionArg||'1';
const actor=actorArg||process.env.R1E_ACTOR_NAME||'R1E Ruleset Registrar';

if(!rulesFile) throw new Error('usage: tsx register-ruleset.ts <rules.json> [code] [version] [actor]');

async function main(){
  const rules=JSON.parse(await readFile(rulesFile,'utf8'));
  const run=await startPersistentRun(
    pool,'RETAIL_R1E_RULESET_REGISTER','user',actor,actor,
    'retail.r1e_match_rulesets'
  );
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','user',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[actor]);
    const r=await c.query(`
      insert into retail.r1e_match_rulesets(
        ruleset_code,ruleset_version,rules_json,rules_sha256,
        certification_status,qa_evidence_json,qa_evidence_sha256,
        created_by
      ) values(
        $1,$2,$3::jsonb,repeat('0',64),
        'draft','{}'::jsonb,repeat('0',64),$4
      )
      returning id,rules_sha256
    `,[code,version,JSON.stringify(rules),actor]);
    await c.query('commit');
    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});
    console.log(JSON.stringify({
      event:'r1e_ruleset_registered',
      rulesetId:r.rows[0].id,
      rulesSha256:r.rows[0].rules_sha256,
      processRunId:run.runId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e);
    throw e;
  }finally{c.release();await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
