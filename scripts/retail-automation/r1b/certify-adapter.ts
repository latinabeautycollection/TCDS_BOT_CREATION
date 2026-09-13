import { Pool } from 'pg';
import { createHash,randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { attestableSha } from './artifact-hash';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [adapterId,evidenceFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1B_APPROVER;
const repoRoot=path.resolve(process.env.REPO_ROOT??process.cwd());
if(!adapterId||!evidenceFile||!actor){
  throw new Error('usage: tsx certify-adapter.ts <adapter_uuid> <evidence_file> <certifier>');
}
const sha=(b:Buffer|string)=>createHash('sha256').update(b).digest('hex');

async function main(){
  const evidenceSha=sha(await readFile(evidenceFile));
  const correlationId=randomUUID();

  // Create the provenance row OUTSIDE the mutation transaction so a failed
  // certification attempt remains visible after rollback.
  const run=await pool.query(`
    insert into arb.process_runs(
      process_name,process_stage,status,correlation_id,
      actor_type,actor_id,actor_name,
      worker_name,worker_instance_id,code_version,ruleset_version,
      entity_type,idempotency_key
    ) values(
      'RETAIL_R1B_ADAPTER_CERTIFY','EXECUTE','STARTED',$1,
      'user',$2,$2,
      'r1b-adapter-certifier',$3,$4,'r1b-v4.0.0',
      'retail.retail_search_adapters',$5
    ) returning run_id
  `,[correlationId,actor,
     process.env.WORKER_INSTANCE_ID??'r1b-v4-1',
     process.env.CODE_VERSION??process.env.GIT_SHA??'unknown',
     `RETAIL_R1B_ADAPTER_CERTIFY:${adapterId}:${correlationId}`]);
  const runId=run.rows[0].run_id;

  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','user',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[actor]);
    await c.query(`select set_config('app.process_run_id',$1,true)`,[runId]);
    await c.query(`select set_config('app.correlation_id',$1,true)`,[correlationId]);

    const q=await c.query(`
      select a.*,
             s.implementation_root,
             s.implementation_authority_type,
             s.package_tree_sha256,
             s.entrypoint_sha256
      from retail.retail_search_adapters a
      join retail.retail_scraper_assets s on s.id=a.scraper_asset_id
      where a.id=$1
      for update of a
    `,[adapterId]);

    if(!q.rowCount) throw new Error('adapter/scraper asset not found');
    const a=q.rows[0];

    const artifactPath=path.resolve(repoRoot,a.implementation_root);
    const observed=await attestableSha(
      a.implementation_authority_type,artifactPath
    );
    const expected=a.implementation_authority_type==='package_tree'
      ? a.package_tree_sha256
      : (a.entrypoint_sha256??a.implementation_sha256);

    if(observed!==expected){
      throw new Error(
        `deployed scraper authority SHA differs from inventoried asset: expected=${expected} observed=${observed}`
      );
    }

    const prepared=await c.query(
      `select retail.r1b_scraper_contract_prepared_for_adapter($1) ok`,
      [adapterId]
    );
    if(prepared.rows[0]?.ok!==true){
      throw new Error('scraper asset/contract is not prepared for adapter certification');
    }

    let gitCommit:string|null=null;
    try{
      gitCommit=execFileSync(
        'git',['rev-parse','HEAD'],{cwd:repoRoot,encoding:'utf8'}
      ).trim();
    }catch{}

    await c.query(
      `select retail.r1b_certify_adapter($1,$2,$3,$4)`,
      [adapterId,evidenceSha,gitCommit,actor]
    );

    await c.query('commit');

    await pool.query(`
      update arb.process_runs
      set status='SUCCEEDED',completed_at=now(),
          rows_seen=1,rows_succeeded=1,rows_failed=0,updated_at=now()
      where run_id=$1
    `,[runId]);

    console.log(JSON.stringify({
      event:'r1b_adapter_certified_with_existing_scraper_authority',
      adapterId,
      authorityType:a.implementation_authority_type,
      implementationRoot:a.implementation_root,
      observedAuthoritySha256:observed,
      evidenceSha256:evidenceSha,
      gitCommitSha:gitCommit,
      processRunId:runId,
      correlationId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await pool.query(`
      update arb.process_runs
      set status='FAILED',failed_at=now(),
          rows_seen=1,rows_succeeded=0,rows_failed=1,
          error_class=$2,error_summary=$3,updated_at=now()
      where run_id=$1
    `,[runId,(e as Error).name,String((e as Error).message??e).slice(0,2000)]);
    throw e;
  }finally{
    c.release(); await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
