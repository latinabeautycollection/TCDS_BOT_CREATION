import { Pool } from 'pg';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { startRun,finishRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [adapterId,evidenceFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1B_APPROVER;
const repoRoot=process.env.REPO_ROOT??process.cwd();
if(!adapterId||!evidenceFile||!actor) throw new Error('usage: tsx certify-adapter.ts <adapter_uuid> <evidence_file> <certifier>');
const sha=(b:Buffer|string)=>createHash('sha256').update(b).digest('hex');

async function main(){
  const evidenceSha=sha(await readFile(evidenceFile));
  const c=await pool.connect(); let runId:string|undefined;
  try{
    await c.query('begin');
    const run=await startRun(c,'RETAIL_R1B_ADAPTER_CERTIFY','user',actor,actor,'retail.retail_search_adapters');
    runId=run.runId;

    const a=await c.query(`select * from retail.retail_search_adapters where id=$1 for update`,[adapterId]);
    if(!a.rowCount) throw new Error('adapter not found');
    const implSha=sha(await readFile(path.resolve(repoRoot,a.rows[0].implementation_ref)));
    if(implSha!==a.rows[0].implementation_sha256) throw new Error('actual implementation SHA differs from inventoried adapter');

    let gitCommit:string|null=null;
    try{gitCommit=execFileSync('git',['rev-parse','HEAD'],{cwd:repoRoot,encoding:'utf8'}).trim();}catch{}

    await c.query(`select retail.r1b_certify_adapter($1,$2,$3,$4)`,[adapterId,evidenceSha,gitCommit,actor]);
    await finishRun(c,run.runId,'SUCCEEDED');
    await c.query('commit');

    console.log(JSON.stringify({event:'r1b_adapter_certified',adapterId,implementationSha256:implSha,evidenceSha256:evidenceSha,gitCommitSha:gitCommit,processRunId:run.runId},null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    if(runId){const d=await pool.connect();try{await finishRun(d,runId,'FAILED',e);}finally{d.release();}}
    throw e;
  }finally{c.release();await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
