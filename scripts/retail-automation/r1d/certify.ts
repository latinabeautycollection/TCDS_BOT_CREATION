import { Pool } from 'pg';
import { createHash,randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFile,writeFile } from 'node:fs/promises';
import path from 'node:path';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const actor=process.env.R1D_CERTIFIER||'R1D Certification Authority';
const packageFile=process.env.R1D_PACKAGE_ZIP;
const outFile=process.env.R1D_CERT_EVIDENCE_OUT||
  'r1d-v2-certification-evidence.json';

if(!packageFile){
  throw new Error('R1D_PACKAGE_ZIP must point to the exact release ZIP being certified');
}

function shaBytes(b:Buffer){
  return createHash('sha256').update(b).digest('hex');
}

function canonicalize(value:any):any{
  if(Array.isArray(value)) return value.map(canonicalize);
  if(value&&typeof value==='object'){
    return Object.keys(value).sort().reduce((o:any,k)=>{
      o[k]=canonicalize(value[k]);
      return o;
    },{});
  }
  return value;
}

function canonicalStringify(value:any){
  return JSON.stringify(canonicalize(value));
}

function runJson(script:string,extraEnv:Record<string,string>={}){
  try{
    const raw=execFileSync(
      process.execPath,
      ['--import','tsx',script],
      {
        cwd:process.env.REPO_ROOT??process.cwd(),
        encoding:'utf8',
        env:{...process.env,...extraEnv}
      }
    );
    return JSON.parse(raw);
  }catch(e:any){
    return {
      allPassed:false,
      error:String(e?.stderr||e?.message||e),
      gates:[]
    };
  }
}

async function main(){
  const releaseBytes=await readFile(path.resolve(packageFile!));
  const releaseSha=shaBytes(releaseBytes);
  if(!/^[0-9a-f]{64}$/.test(releaseSha)){
    throw new Error('Release ZIP hashing failed');
  }

  const c=await pool.connect();
  const correlationId=randomUUID();
  let runId:string|undefined;

  try{
    const run=await c.query(`
      insert into arb.process_runs(
        process_name,process_stage,status,correlation_id,
        actor_type,actor_id,actor_name,
        worker_name,worker_instance_id,code_version,ruleset_version,
        entity_type,idempotency_key
      ) values(
        'RETAIL_R1D_CERTIFY','FREEZE_GATE','STARTED',$1,
        'system','r1d-certifier',$2,
        'r1d-certify',$3,$4,'r1d-v2.0.0',
        'retail.r1d',$5
      ) returning run_id
    `,[
      correlationId,actor,
      process.env.WORKER_INSTANCE_ID??'r1d-v2-cert-1',
      process.env.CODE_VERSION??'unknown',
      `R1D_V2_CERT:${correlationId}`
    ]);
    runId=run.rows[0].run_id;

    const binding=await c.query(`
      select b.*,cr.certification_version,cr.certification_status
      from retail.r1d_r1c_certification_binding b
      join retail.r1c_certification_runs cr
        on cr.id=b.r1c_certification_run_id
      where b.singleton=true
    `);
    if(!binding.rowCount||
       (await c.query(`select retail.r1d_r1c_binding_is_current() ok`)).rows[0].ok!==true){
      throw new Error('Exact current R1C V3 binding missing/stale');
    }

    const passive:any[]=[];
    const add=(name:string,ok:boolean,detail:any={})=>passive.push({name,ok,detail});
    const count=async(sql:string)=>Number((await c.query(sql)).rows[0].n);

    add('r1d_v2_state',
      (await c.query(`select exists(select 1 from retail.r1d_v2_state where singleton and hardening_version='2.0.0') ok`)).rows[0].ok===true);
    add('r1c_v3_binding_current',true);
    add('global_daily_budget_exactly_one',
      (await count(`select count(*)::int n from retail.r1d_budget_policies where active and scope_type='GLOBAL' and period_kind='DAILY'`))===1);
    add('global_monthly_budget_exactly_one',
      (await count(`select count(*)::int n from retail.r1d_budget_policies where active and scope_type='GLOBAL' and period_kind='MONTHLY'`))===1);
    add('active_cost_profiles_bounded',
      (await count(`select count(*)::int n from retail.r1d_cost_profiles where active and (max_execution_cost_usd is null or violation_status<>'clear')`))===0);
    add('no_cost_model_violations',
      (await count(`select count(*)::int n from retail.r1d_cost_model_violations`))===0);
    add('all_effective_platforms_rate_governed',
      (await count(`
        select count(*)::int n
        from (select distinct platform_id from retail.effective_compiled_search_jobs) p
        where not exists(
          select 1 from retail.r1d_rate_policies rp
          where rp.platform_id=p.platform_id and rp.active
        )
      `))===0);
    add('current_dispatch_bindings_nonempty',
      (await count(`select count(*)::int n from retail.r1d_dispatch_bindings where retail.r1d_dispatch_binding_is_current(id)`))>0);
    add('no_legacy_certified_node_file',
      (await count(`select count(*)::int n from retail.r1d_dispatch_bindings where certification_status='certified' and runner_kind='node_file'`))===0);
    add('effective_compiled_jobs_nonempty',
      (await count(`select count(*)::int n from retail.effective_compiled_search_jobs`))>0);
    add('schedule_state_complete',
      (await count(`
        select count(*)::int n from retail.effective_compiled_search_jobs ec
        where not exists(
          select 1 from retail.r1d_compilation_schedule_state s
          where s.compilation_id=ec.id
        )
      `))===0);
    add('no_stale_production_queue',
      (await count(`
        select count(*)::int n from retail.r1d_dispatch_jobs q
        where q.certification_fixture=false
          and q.status in('queued','retry_wait')
          and (
            not exists(
              select 1 from retail.effective_compiled_search_jobs ec
              where ec.id=q.compilation_id
                and ec.route_authority_hash=q.route_authority_hash
                and ec.adapter_payload_sha256=q.adapter_payload_sha256
                and ec.compiler_authority_sha256=q.compiler_authority_sha256
            )
            or retail.r1d_dispatch_binding_is_current(q.dispatch_binding_id) is not true
          )
      `))===0);

    const fixturePrep=runJson(
      'scripts/retail-automation/r1d/prepare-certification-fixtures.ts',
      {R1D_CERT_FIXTURE_COUNT:process.env.R1D_CERT_FIXTURE_COUNT??'8'}
    );
    const active=runJson(
      'scripts/retail-automation/r1d/adversarial-tests-v2.ts'
    );
    const concurrency=runJson(
      'scripts/retail-automation/r1d/concurrency-tests.ts',
      {
        R1D_RUN_CONCURRENCY_TESTS:'true',
        R1D_CONCURRENCY_WORKERS:process.env.R1D_CONCURRENCY_WORKERS??'8'
      }
    );

    const fixturePass=!!fixturePrep.fixtureIds&&fixturePrep.fixtureIds.length>=2;
    const activePass=active.allPassed===true;
    const concurrencyPass=concurrency.allPassed===true;
    const pass=passive.every(x=>x.ok)&&fixturePass&&activePass&&concurrencyPass;

    const evidence={
      certificationVersion:'r1d-v2.0.0',
      processRunId:runId,
      correlationId,
      createdAt:new Date().toISOString(),
      r1cBinding:binding.rows[0],
      r1dReleaseZip:path.basename(packageFile!),
      r1dReleaseZipSha256:releaseSha,
      passiveResults:passive,
      certificationFixturePreparation:fixturePrep,
      adversarialResults:active.gates??[],
      concurrencyResults:concurrency
    };

    const canonicalText=canonicalStringify(evidence);
    const seal=shaBytes(Buffer.from(canonicalText,'utf8'));
    await writeFile(
      outFile,
      JSON.stringify({
        manifest:canonicalize(evidence),
        canonicalManifestText:canonicalText,
        evidenceManifestSha256:seal
      },null,2)
    );

    const activeGates=active.gates??[];
    const concurrencyGates=concurrency.gates??[];
    const total=passive.length+1+activeGates.length+concurrencyGates.length;
    const passed=
      passive.filter(x=>x.ok).length+(fixturePass?1:0)
      +activeGates.filter((x:any)=>x.ok).length
      +concurrencyGates.filter((x:any)=>x.ok).length;

    // Seal the certification row and its governing ARB process-run status in
    // one PostgreSQL transaction. A partial "CERTIFIED row / STARTED run" state
    // is therefore impossible.
    await c.query('begin');
    try{
      await c.query(`
        insert into retail.r1d_certification_runs(
          process_run_id,certification_version,
          r1c_certification_run_id,r1c_package_sha256,
          r1d_package_sha256,
          passive_results,active_results,concurrency_results,
          evidence_manifest,evidence_manifest_text,evidence_manifest_sha256,
          release_zip_sha256,
          total_gates,passed_gates,failed_gates,
          certification_status,certified_by
        ) values(
          $1,'r1d-v2.0.0',$2,$3,$4,
          $5::jsonb,$6::jsonb,$7::jsonb,
          $8::jsonb,$9,$10,$11,
          $12,$13,$14,$15,$16
        )
      `,[
        runId,binding.rows[0].r1c_certification_run_id,
        binding.rows[0].r1c_package_sha256,
        releaseSha,
        JSON.stringify(passive),
        JSON.stringify(activeGates),
        JSON.stringify(concurrency),
        canonicalText,canonicalText,seal,releaseSha,
        total,passed,total-passed,
        pass?'CERTIFIED':'FAILED',actor
      ]);

      await c.query(`
        update arb.process_runs
        set status=$2,certification_status=$3,
            certification_report_json=$4::jsonb,
            completed_at=case when $2='SUCCEEDED' then now() else completed_at end,
            failed_at=case when $2='FAILED' then now() else failed_at end,
            updated_at=now()
        where run_id=$1
      `,[
        runId,pass?'SUCCEEDED':'FAILED',pass?'CERTIFIED':'FAILED',
        JSON.stringify({
          releaseZipSha256:releaseSha,
          evidenceManifestSha256:seal,
          outFile,fixturePass,activePass,concurrencyPass
        })
      ]);
      await c.query('commit');
    }catch(e){
      await c.query('rollback').catch(()=>undefined);
      throw e;
    }

    console.log(JSON.stringify({
      certification:pass?'CERTIFIED':'FAILED',
      processRunId:runId,
      releaseZipSha256:releaseSha,
      evidenceManifestSha256:seal,
      outFile,passive,fixturePrep,active,concurrency
    },null,2));

    if(!pass) process.exitCode=2;
  }catch(e){
    if(runId){
      await c.query(`
        update arb.process_runs
        set status='FAILED',certification_status='FAILED',
            error_summary=$2,failed_at=now(),updated_at=now()
        where run_id=$1
      `,[runId,String((e as Error).message??e).slice(0,2000)]);
    }
    throw e;
  }finally{
    c.release(); await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
