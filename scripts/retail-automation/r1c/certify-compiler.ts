import { Pool } from 'pg';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [compilerId,evidenceFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1C_CERTIFIER;
if(!compilerId||!evidenceFile||!actor){
  throw new Error('usage: tsx certify-compiler.ts <compiler_uuid> <qa_evidence_file> <certifier>');
}
const sha=(b:Buffer|string)=>createHash('sha256').update(b).digest('hex');

async function main(){
  const evidenceSha=sha(await readFile(evidenceFile));
  const run=await startPersistentRun(
    pool,'RETAIL_R1C_COMPILER_CERTIFY','user',
    actor,actor,'retail.search_compiler_versions'
  );
  const c=await pool.connect();
  try{
    await c.query('begin');

    const v=await c.query(`
      select * from retail.search_compiler_versions
      where id=$1 and certification_status='uncertified'
      for update
    `,[compilerId]);
    if(!v.rowCount) throw new Error('uncertified compiler version not found');
    const row=v.rows[0];
    if(!row.hardening_migration_sha256){
      throw new Error('R1C V3 compiler missing hardening migration SHA');
    }

    await c.query(`
      select retail.r1c_certify_compiler($1,$2,$3,$4,$5)
    `,[compilerId,evidenceSha,run.runId,run.correlationId,actor]);

    const x=await c.query(`
      select * from retail.search_compiler_versions where id=$1
    `,[compilerId]);

    await c.query('commit');
    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});

    console.log(JSON.stringify({
      event:'r1c_v3_compiler_certified',
      compiler:x.rows[0],
      processRunId:run.runId,
      correlationId:run.correlationId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e);
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
