import { Pool } from 'pg';
import { createHash,randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { writeFile } from 'node:fs/promises';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [compilerId]=process.argv.slice(2);
const actor=process.env.R1C_CERTIFIER||'R1C Certification Authority';
const packageSha=process.env.R1C_PACKAGE_SHA256;
const outFile=process.env.R1C_CERT_EVIDENCE_OUT||
  'r1c-v3-certification-evidence.json';

if(!compilerId||!packageSha){
  throw new Error(
    'usage: R1C_PACKAGE_SHA256=<sha> tsx certify.ts <compiler_uuid>'
  );
}
if(!/^[0-9a-f]{64}$/.test(packageSha)){
  throw new Error(
    'R1C_PACKAGE_SHA256 must be lowercase 64-char SHA-256'
  );
}

const sha=(s:string)=>createHash('sha256').update(s).digest('hex');

function runAdversarialSuite(){
  try{
    const raw=execFileSync(
      process.execPath,
      ['--import','tsx','scripts/retail-automation/r1c/adversarial-tests.ts'],
      {
        cwd:process.env.REPO_ROOT??process.cwd(),
        encoding:'utf8',
        env:process.env
      }
    );
    return JSON.parse(raw);
  }catch(e:any){
    return {
      allPassed:false,
      error:String(e?.stderr||e?.message||e),
      gates:[],
      passed:0,
      failed:1
    };
  }
}

async function main(){
  const c=await pool.connect();
  const correlationId=randomUUID();
  let runId:string|undefined;

  try{
    const run=await c.query(`
      insert into arb.process_runs(
        process_name,process_stage,status,correlation_id,
        actor_type,actor_id,actor_name,
        worker_name,worker_instance_id,
        code_version,ruleset_version,
        entity_type,idempotency_key
      ) values(
        'RETAIL_R1C_CERTIFY','FREEZE_GATE','STARTED',$1,
        'system','r1c-certifier',$2,
        'r1c-certify',$3,$4,'r1c-v3.0.0',
        'retail.r1c',$5
      )
      returning run_id
    `,[
      correlationId,actor,
      process.env.WORKER_INSTANCE_ID??'r1c-v3-cert-1',
      process.env.CODE_VERSION??'unknown',
      `R1C_V3_CERT:${correlationId}`
    ]);
    runId=run.rows[0].run_id;

    const binding=await c.query(`
      select b.*,
             cr.certification_status,
             cr.certification_version
      from retail.r1c_r1b_certification_binding b
      join retail.r1b_certification_runs cr
        on cr.id=b.r1b_certification_run_id
      where b.singleton=true
    `);

    if(
      !binding.rowCount
      || (await c.query(
        `select retail.r1c_r1b_binding_is_current() ok`
      )).rows[0].ok!==true
    ){
      throw new Error('Exact current R1B V4 binding missing/stale');
    }

    const b=binding.rows[0];
    if(
      b.r1b_scraper_hardening_version!=='4.0.0'
      || b.r1b_certification_version!=='r1b-v4.0.0'
      || b.certification_version!=='r1b-v4.0.0'
      || b.certification_status!=='CERTIFIED'
    ){
      throw new Error('R1C V3 requires R1B V4 CERTIFIED authority');
    }

    const comp=await c.query(`
      select * from retail.search_compiler_versions
      where id=$1
        and certification_status='certified'
        and hardening_migration_sha256 is not null
    `,[compilerId]);
    if(!comp.rowCount){
      throw new Error('R1C V3 certified compiler not found');
    }

    const compiler=comp.rows[0];
    const passive:any[]=[];
    const add=(name:string,ok:boolean,detail:any={})=>
      passive.push({name,ok,detail});

    add(
      'r1b_v4_binding_current',
      (await c.query(
        `select retail.r1c_r1b_binding_is_current() ok`
      )).rows[0].ok===true
    );

    add(
      'r1b_scraper_hardening_current',
      (await c.query(`
        select exists(
          select 1 from retail.r1b_scraper_authority_state
          where singleton=true and hardening_version='4.0.0'
        ) ok
      `)).rows[0].ok===true
    );

    add(
      'compiler_authority_reproducible',
      compiler.compiler_authority_sha256===
      (await c.query(`
        select retail.r1c_sha256_jsonb(
          retail.r1c_compiler_authority_document(x)
        ) h
        from retail.search_compiler_versions x
        where id=$1
      `,[compilerId])).rows[0].h
    );

    add(
      'compiler_functions_current',
      (await c.query(`
        select retail.r1c_compiler_functions_current($1) ok
      `,[compilerId])).rows[0].ok===true
    );

    const badJobs=await c.query(`
      select count(*)::int n
      from retail.search_job_compilations
      where compilation_status='compiled'
        and retail.r1c_compilation_is_current(id) is not true
    `);
    add(
      'all_compiled_jobs_current',
      badJobs.rows[0].n===0,
      badJobs.rows[0]
    );

    const effectiveCount=Number((await c.query(`
      select count(*)::int n
      from retail.effective_compiled_search_jobs
    `)).rows[0].n);
    add('effective_jobs_nonempty',effectiveCount>0,{count:effectiveCount});

    const packageCount=Number((await c.query(`
      select count(*)::int n
      from retail.effective_compiled_search_jobs j
      join retail.retail_search_adapters a on a.id=j.adapter_id
      join retail.retail_scraper_assets s on s.id=a.scraper_asset_id
      where s.implementation_authority_type
              in ('file','package_tree')
    `)).rows[0].n);
    add(
      'certified_scraper_execution_fixture_nonempty',
      packageCount>0,
      {count:packageCount}
    );

    const contractEvidenceBad=Number((await c.query(`
      select count(*)::int n
      from retail.effective_compiled_search_jobs j
      where (j.compilation_evidence_json->'scraper_authority'->>'scraper_contract_id') is null
         or (j.compilation_evidence_json->'scraper_authority'->>'scraper_contract_sha256') is null
         or (j.compilation_evidence_json->'scraper_authority'->>'scraper_asset_id') is null
    `)).rows[0].n);
    add(
      'explicit_scraper_authority_evidence_complete',
      contractEvidenceBad===0,
      {bad:contractEvidenceBad}
    );

    const active=runAdversarialSuite();

    const replayRows=await c.query(`
      select j.id,
        j.normalized_job_sha256=
          retail.r1c_sha256_jsonb(
            retail.r1c_normalized_job_document(
              j.route_id,j.compile_profile_id
            )
          ) normalized_same,
        j.adapter_payload_sha256=
          retail.r1c_sha256_jsonb(
            retail.r1c_adapter_payload_document(
              j.route_id,j.compile_profile_id
            )
          ) payload_same,
        j.compilation_evidence_json->'scraper_authority'=
          retail.r1c_scraper_authority_document(j.adapter_id)
          scraper_same
      from retail.effective_compiled_search_jobs j
    `);

    const replay={
      count:replayRows.rowCount,
      allByteEquivalent:
        replayRows.rowCount>0
        && replayRows.rows.every(
          x=>x.normalized_same&&x.payload_same&&x.scraper_same
        ),
      rows:replayRows.rows
    };

    const replayPass=
      replay.count>0&&replay.allByteEquivalent;

    const evidence={
      certificationVersion:'r1c-v3.0.0',
      processRunId:runId,
      correlationId,
      createdAt:new Date().toISOString(),
      r1bBinding:b,
      r1bCertificationVersion:'r1b-v4.0.0',
      r1bScraperHardeningVersion:'4.0.0',
      r1cPackageSha256:packageSha,
      compilerAuthoritySha256:compiler.compiler_authority_sha256,
      compilerHardeningMigrationSha256:
        compiler.hardening_migration_sha256,
      passiveResults:passive,
      adversarialResults:active.gates??[],
      replayResults:replay
    };

    const manifestCanonical=JSON.stringify(evidence);
    const seal=sha(manifestCanonical);
    const envelope={
      manifest:evidence,
      evidenceManifestSha256:seal
    };
    await writeFile(outFile,JSON.stringify(envelope,null,2));

    const activePass=active.allPassed===true;
    const pass=
      passive.every(x=>x.ok)
      && activePass
      && replayPass;

    const activeGates=active.gates??[];
    const total=passive.length+activeGates.length+1;
    const passed=
      passive.filter(x=>x.ok).length
      +activeGates.filter((x:any)=>x.ok).length
      +(replayPass?1:0);

    await c.query(`
      insert into retail.r1c_certification_runs(
        process_run_id,certification_version,
        r1b_certification_run_id,r1b_package_sha256,
        r1c_package_sha256,
        compiler_version_id,compiler_authority_sha256,
        passive_results,active_results,replay_results,
        evidence_manifest,evidence_manifest_sha256,
        total_gates,passed_gates,failed_gates,
        certification_status,certified_by,
        r1b_certification_version,
        r1b_scraper_hardening_version
      ) values(
        $1,'r1c-v3.0.0',$2,$3,$4,$5,$6,
        $7::jsonb,$8::jsonb,$9::jsonb,$10::jsonb,$11,
        $12,$13,$14,$15,$16,
        'r1b-v4.0.0','4.0.0'
      )
    `,[
      runId,b.r1b_certification_run_id,b.r1b_package_sha256,
      packageSha,compilerId,compiler.compiler_authority_sha256,
      JSON.stringify(passive),
      JSON.stringify(activeGates),
      JSON.stringify(replay),
      JSON.stringify(evidence),
      seal,total,passed,total-passed,
      pass?'CERTIFIED':'FAILED',actor
    ]);

    await c.query(`
      update arb.process_runs
      set status=$2,
          certification_status=$3,
          certification_report_json=$4::jsonb,
          completed_at=case when $2='SUCCEEDED' then now() else completed_at end,
          failed_at=case when $2='FAILED' then now() else failed_at end,
          updated_at=now()
      where run_id=$1
    `,[
      runId,
      pass?'SUCCEEDED':'FAILED',
      pass?'CERTIFIED':'FAILED',
      JSON.stringify({
        evidenceManifestSha256:seal,
        outFile,
        passivePass:passive.every(x=>x.ok),
        adversarialPass:activePass,
        replayPass
      })
    ]);

    console.log(JSON.stringify({
      certification:pass?'CERTIFIED':'FAILED',
      processRunId:runId,
      evidenceManifestSha256:seal,
      outFile,
      passive,
      adversarial:active,
      replay
    },null,2));

    if(!pass) process.exitCode=2;
  }catch(e){
    if(runId){
      await c.query(`
        update arb.process_runs
        set status='FAILED',
            certification_status='FAILED',
            error_summary=$2,
            failed_at=now(),
            updated_at=now()
        where run_id=$1
      `,[
        runId,
        String((e as Error).message??e).slice(0,2000)
      ]);
    }
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}

main().catch(e=>{
  console.error(e);
  process.exitCode=1;
});
