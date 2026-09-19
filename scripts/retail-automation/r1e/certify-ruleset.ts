import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [rulesetId,evidenceFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1E_CERTIFIER;

if(!rulesetId||!evidenceFile||!actor){
  throw new Error('usage: tsx certify-ruleset.ts <ruleset_uuid> <qa_evidence.json> <certifier>');
}

async function main(){
  const evidence=JSON.parse(await readFile(evidenceFile,'utf8'));
  const run=await startPersistentRun(
    pool,'RETAIL_R1E_RULESET_CERTIFY','user',actor,actor,
    'retail.r1e_match_rulesets'
  );
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`
      select retail.r1e_certify_ruleset_v2($1,$2::jsonb,$3,$4,$5)
    `,[rulesetId,JSON.stringify(evidence),run.runId,run.correlationId,actor]);

    const q=await c.query(`select * from retail.r1e_match_rulesets where id=$1`,[rulesetId]);
    await c.query('commit');

    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});
    console.log(JSON.stringify({
      event:'r1e_v2_ruleset_certified',
      ruleset:q.rows[0],processRunId:run.runId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e);
    throw e;
  }finally{
    c.release();await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
