import { Pool } from 'pg';
import { spawn,ChildProcessWithoutNullStreams } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { startPersistentRun,finishPersistentRun } from './provenance';
import { attestableSha,shaFile } from './artifact-hash';
import type { ClaimedJobV2 } from './types';

const pool=new Pool({
  connectionString:process.env.DATABASE_URL,
  max:Number(process.env.R1D_DB_POOL_MAX??'5')
});

const workerId=process.env.R1D_WORKER_ID||
  `${process.env.HOSTNAME||'host'}:${process.pid}`;
const repoRoot=path.resolve(process.env.RETAIL_REPO_ROOT||process.cwd());
const idleMinMs=Number(process.env.R1D_IDLE_MIN_MS??'1000');
const idleMaxMs=Number(process.env.R1D_IDLE_MAX_MS??'5000');

const r1cWrapper=process.env.R1C_COMPILER_WRAPPER;
const r1cBaseMigration=process.env.R1C_BASE_MIGRATION;
const r1cV3Migration=process.env.R1C_V3_MIGRATION;
const r1cPackage=process.env.R1C_PACKAGE_ZIP;

for(const [name,value] of Object.entries({
  R1C_COMPILER_WRAPPER:r1cWrapper,
  R1C_BASE_MIGRATION:r1cBaseMigration,
  R1C_V3_MIGRATION:r1cV3Migration,
  R1C_PACKAGE_ZIP:r1cPackage
})){
  if(!value) throw new Error(`${name} is required`);
}

const MAX_TAIL=65536;
const RESERVED_PAYLOAD_ENV=new Set([
  'PATH','NODE_OPTIONS','NODE_PATH','LD_PRELOAD','LD_LIBRARY_PATH',
  'DATABASE_URL','PGHOST','PGPORT','PGUSER','PGPASSWORD','PGDATABASE',
  'HOME','SHELL','TMPDIR','TEMP','TMP',
  'R1D_WORKER_ID','RETAIL_REPO_ROOT',
  'R1C_COMPILER_WRAPPER','R1C_BASE_MIGRATION','R1C_V3_MIGRATION',
  'R1C_PACKAGE_ZIP'
]);

const sleep=(ms:number)=>new Promise(r=>setTimeout(r,ms));
const jitter=()=>Math.floor(idleMinMs+Math.random()*(idleMaxMs-idleMinMs+1));

function scalar(v:unknown){
  if(v===null||v===undefined) return '';
  if(typeof v==='string') return v;
  if(typeof v==='number'||typeof v==='boolean') return String(v);
  return JSON.stringify(v);
}

function validatePayloadEnvName(name:string,allowed:Set<string>){
  if(!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)){
    throw new Error(`Unsafe payload environment variable name: ${name}`);
  }
  if(RESERVED_PAYLOAD_ENV.has(name)){
    throw new Error(`Payload attempted to override reserved environment variable: ${name}`);
  }
  if(!allowed.has(name)){
    throw new Error(`Payload environment variable not certified by R1B field_map: ${name}`);
  }
}

function buildChildEnv(
  parameters:Record<string,unknown>,
  certifiedFieldMap:Record<string,string>,
  inheritedAllowlist:string[]
){
  const child:NodeJS.ProcessEnv={};
  const inherited=new Set([
    'PATH','HOME','TMPDIR','TEMP','TMP','NODE_ENV',
    ...inheritedAllowlist
  ]);

  for(const name of inherited){
    if(!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)){
      throw new Error(`Invalid inherited environment allowlist name: ${name}`);
    }
    const v=process.env[name];
    if(v!==undefined) child[name]=v;
  }

  const allowedPayload=new Set(Object.values(certifiedFieldMap));
  for(const [name,value] of Object.entries(parameters)){
    validatePayloadEnvName(name,allowedPayload);
    child[name]=scalar(value);
  }
  return child;
}

function buildArgv(
  parameters:Record<string,unknown>,
  certifiedFieldMap:Record<string,string>
){
  const allowed=new Set(Object.values(certifiedFieldMap));
  const args:string[]=[];
  for(const [name,value] of Object.entries(parameters)){
    if(name.includes('\0')||!allowed.has(name)){
      throw new Error(`Uncertified/unsafe argv parameter: ${name}`);
    }
    args.push(name,scalar(value));
  }
  return args;
}

function tailAppend(current:string,chunk:string){
  const x=current+chunk;
  return x.length<=MAX_TAIL?x:x.slice(x.length-MAX_TAIL);
}

function extractMetrics(stdout:string){
  for(const line of stdout.split(/\r?\n/).map(x=>x.trim()).filter(Boolean).reverse()){
    try{
      const x=JSON.parse(line);
      if(x&&typeof x==='object'&&x.r1d_metrics) return x.r1d_metrics;
    }catch{}
  }
  return {};
}

async function runtimeAuthority(job:ClaimedJobV2){
  const q=await pool.query(`
    select
      b.*,
      s.implementation_root,
      s.implementation_authority_type,
      s.entrypoint_ref,
      s.execution_command,
      c.transport,
      c.field_map
    from retail.r1d_dispatch_bindings b
    join retail.retail_scraper_assets s on s.id=b.scraper_asset_id
    join retail.retail_scraper_contracts c on c.id=b.scraper_contract_id
    where b.id=$1
      and retail.r1d_dispatch_binding_is_current(b.id)=true
  `,[job.dispatch_binding_id]);
  if(!q.rowCount) throw new Error('Certified current R1D dispatch binding missing');
  const b=q.rows[0];

  const scraperTarget=path.resolve(repoRoot,b.implementation_root);
  const observedScraperSha=await attestableSha(
    b.implementation_authority_type,scraperTarget
  );
  await pool.query(
    `select retail.r1b_assert_runtime_adapter($1,$2)`,
    [job.adapter_id,observedScraperSha]
  );

  const wrapperSha=await shaFile(path.resolve(r1cWrapper!));
  const baseSha=await shaFile(path.resolve(r1cBaseMigration!));
  const v3Sha=await shaFile(path.resolve(r1cV3Migration!));
  const packageSha=await shaFile(path.resolve(r1cPackage!));

  const compiler=await pool.query(`
    select compiler_version_id
    from retail.effective_compiled_search_jobs
    where id=$1
  `,[job.compilation_id]);
  if(!compiler.rowCount) throw new Error('Compilation ceased to be effective');

  await pool.query(
    `select retail.r1c_assert_runtime_compiler_v3($1,$2,$3,$4)`,
    [compiler.rows[0].compiler_version_id,wrapperSha,baseSha,v3Sha]
  );
  await pool.query(
    `select retail.r1c_assert_runtime_release($1,$2)`,
    [job.compilation_id,packageSha]
  );

  return {
    binding:b,
    observedScraperSha,
    wrapperSha,baseSha,v3Sha,packageSha
  };
}

function launchLocal(job:ClaimedJobV2,b:any){
  const payload=job.adapter_payload_json;
  const parameters=payload.parameters||{};
  const fieldMap=b.field_map||{};
  const policy=b.runner_policy_json||{};
  const inheritedAllowlist=Array.isArray(policy.inherited_env_allowlist)
    ? policy.inherited_env_allowlist
    : [];
  const gracefulKillSeconds=Number(policy.graceful_kill_seconds??5);
  if(!Number.isInteger(gracefulKillSeconds)||gracefulKillSeconds<1||gracefulKillSeconds>60){
    throw new Error('Invalid certified graceful_kill_seconds');
  }

  let stdin:string|null=null;
  let extraArgs:string[]=[];
  let childEnv:NodeJS.ProcessEnv={};

  if(b.payload_delivery==='env'){
    childEnv=buildChildEnv(parameters,fieldMap,inheritedAllowlist);
  }else if(b.payload_delivery==='argv'){
    childEnv=buildChildEnv({},fieldMap,inheritedAllowlist);
    extraArgs=buildArgv(parameters,fieldMap);
  }else if(b.payload_delivery==='stdin_json'){
    childEnv=buildChildEnv({},fieldMap,inheritedAllowlist);
    stdin=JSON.stringify(payload);
  }else if(b.payload_delivery==='env_plus_stdin_json'){
    childEnv=buildChildEnv(parameters,fieldMap,inheritedAllowlist);
    stdin=JSON.stringify(payload);
  }else{
    throw new Error(`Unsupported payload delivery ${b.payload_delivery}`);
  }

  let command:string;
  let args:string[];
  let cwd:string;

  if(b.runner_kind==='node_js'){
    const entry=path.resolve(repoRoot,b.entrypoint_ref);
    command=process.execPath;
    args=[entry,...extraArgs];
    cwd=path.dirname(entry);
  }else if(b.runner_kind==='tsx_file'){
    const entry=path.resolve(repoRoot,b.entrypoint_ref);
    command=process.execPath;
    args=['--import','tsx',entry,...extraArgs];
    cwd=path.dirname(entry);
  }else if(b.runner_kind==='npm_script'){
    const expected=`npm run ${b.npm_script}`;
    if(b.execution_command!==expected){
      throw new Error(
        `Binding npm script no longer equals R1B execution command: ${expected} != ${b.execution_command}`
      );
    }
    command=process.platform==='win32'?'npm.cmd':'npm';
    args=['run',b.npm_script,'--',...extraArgs];
    cwd=path.resolve(repoRoot,b.implementation_root);
  }else{
    throw new Error(`Local launcher cannot run ${b.runner_kind}`);
  }

  const child=spawn(command,args,{
    cwd,
    env:childEnv,
    shell:false,
    windowsHide:true,
    stdio:['pipe','pipe','pipe']
  });

  return {child,stdin,gracefulKillSeconds};
}

async function awaitSpawn(child:ChildProcessWithoutNullStreams){
  await new Promise<void>((resolve,reject)=>{
    const onSpawn=()=>{cleanup();resolve();};
    const onError=(e:Error)=>{cleanup();reject(e);};
    const cleanup=()=>{
      child.off('spawn',onSpawn);
      child.off('error',onError);
    };
    child.once('spawn',onSpawn);
    child.once('error',onError);
  });
}

async function collectChild(
  child:ChildProcessWithoutNullStreams,
  stdin:string|null,
  timeoutSeconds:number,
  gracefulKillSeconds:number
){
  const stdoutHash=createHash('sha256');
  const stderrHash=createHash('sha256');
  let stdoutTail='';
  let stderrTail='';

  return await new Promise<any>((resolve,reject)=>{
    let timedOut=false;
    const timer=setTimeout(()=>{
      timedOut=true;
      child.kill('SIGTERM');
      setTimeout(()=>child.kill('SIGKILL'),gracefulKillSeconds*1000).unref();
    },timeoutSeconds*1000);
    timer.unref();

    child.on('error',reject);
    child.stdout.on('data',(buf:Buffer)=>{
      stdoutHash.update(buf);
      stdoutTail=tailAppend(stdoutTail,buf.toString('utf8'));
    });
    child.stderr.on('data',(buf:Buffer)=>{
      stderrHash.update(buf);
      stderrTail=tailAppend(stderrTail,buf.toString('utf8'));
    });
    child.once('close',(code,signal)=>{
      clearTimeout(timer);
      if(timedOut) stderrTail=tailAppend(stderrTail,'\nR1D_TIMEOUT');
      resolve({
        code,signal,stdoutTail,stderrTail,
        stdoutSha:stdoutHash.digest('hex'),
        stderrSha:stderrHash.digest('hex'),
        metrics:extractMetrics(stdoutTail)
      });
    });

    if(stdin!==null) child.stdin.write(stdin);
    child.stdin.end();
  });
}

async function processOne(){
  const claim=await pool.query(`
    select * from retail.r1d_claim_next_job_v2($1,null,null,false)
  `,[workerId]);

  if(!claim.rowCount) return false;

  const job=claim.rows[0] as ClaimedJobV2;
  const run=await startPersistentRun(
    pool,'RETAIL_R1D_DISPATCH','worker',
    workerId,workerId,'retail.r1d_dispatch_jobs'
  );

  await pool.query(`
    select retail.r1d_attach_claim_provenance(
      $1,$2,$3,$4
    )
  `,[job.job_id,job.attempt_no,run.runId,run.correlationId]);

  try{
    let auth:any;
    try{
      auth=await runtimeAuthority(job);
    }catch(e){
      await pool.query(`
        select retail.r1d_fail_pre_dispatch(
          $1,$2,'AUTHORITY_ATTESTATION_FAILED',$3,true,$4,$5
        )
      `,[
        job.job_id,job.lease_token,
        String((e as Error).message??e),
        run.runId,run.correlationId
      ]);
      throw e;
    }

    const b=auth.binding;

    if(b.runner_kind==='external_queue'){
      const outbox=await pool.query(`
        select retail.r1d_enqueue_external_attempt(
          $1,$2,$3,$4::jsonb
        ) outbox_message_id
      `,[
        job.job_id,job.lease_token,job.dispatch_binding_id,
        JSON.stringify(job.adapter_payload_json)
      ]);

      await finishPersistentRun(
        pool,run.runId,'SUCCEEDED',
        {seen:1,succeeded:1,failed:0},
        undefined,{
          mode:'external_queue',
          jobId:job.job_id,
          outboxMessageId:outbox.rows[0].outbox_message_id
        }
      );

      console.log(JSON.stringify({
        event:'r1d_external_attempt_enqueued',
        jobId:job.job_id,
        attemptNo:job.attempt_no,
        outboxMessageId:outbox.rows[0].outbox_message_id
      }));
      return true;
    }

    let launched;
    try{
      launched=launchLocal(job,b);
      await awaitSpawn(launched.child);
    }catch(e){
      await pool.query(`
        select retail.r1d_fail_pre_dispatch(
          $1,$2,'PROCESS_SPAWN_FAILED',$3,false,$4,$5
        )
      `,[
        job.job_id,job.lease_token,
        String((e as Error).message??e),
        run.runId,run.correlationId
      ]);
      throw e;
    }

    // Only now has an OS process actually started.
    await pool.query(
      `select retail.r1d_mark_dispatching($1,$2)`,
      [job.job_id,job.lease_token]
    );

    const result=await collectChild(
      launched.child,
      launched.stdin,
      Number(b.timeout_seconds),
      launched.gracefulKillSeconds
    );

    const success=result.code===0;
    const reported=Number(result.metrics?.actual_cost_usd);
    const hasActual=Number.isFinite(reported)&&reported>=0;
    const actualCost=hasActual?reported:Number(job.estimated_cost_usd);
    const costBasis=hasActual?'actual':'estimated';

    await pool.query(`
      select retail.r1d_finish_job(
        $1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9,$10,$11,$12,$13,$14,$15
      )
    `,[
      job.job_id,job.lease_token,success,
      actualCost,costBasis,
      success?null:'WORKER_EXIT_NONZERO',
      success?null:`Worker exit code=${result.code} signal=${result.signal}`,
      JSON.stringify(result.metrics||{}),
      result.code,result.stdoutTail,result.stderrTail,
      result.stdoutSha,result.stderrSha,
      run.runId,run.correlationId
    ]);

    await finishPersistentRun(
      pool,run.runId,
      success?'SUCCEEDED':'FAILED',
      {seen:1,succeeded:success?1:0,failed:success?0:1},
      success?undefined:new Error(`worker exit ${result.code}`),
      {
        jobId:job.job_id,
        attemptNo:job.attempt_no,
        actualCostUsd:actualCost,
        costBasis,
        scraperAuthoritySha256:auth.observedScraperSha
      }
    );

    if(!success) console.error(`R1D job ${job.job_id} failed; retry/dead-letter state recorded`);
    return true;
  }catch(e){
    const current=await pool.query(
      `select status from retail.r1d_dispatch_jobs where id=$1`,
      [job.job_id]
    ).catch(()=>({rowCount:0,rows:[]} as any));

    if(current.rowCount&&current.rows[0].status==='leased'){
      await pool.query(`
        select retail.r1d_fail_pre_dispatch(
          $1,$2,'DISPATCHER_INTERNAL_ERROR',$3,false,$4,$5
        )
      `,[
        job.job_id,job.lease_token,
        String((e as Error).message??e),
        run.runId,run.correlationId
      ]).catch(()=>undefined);
    }

    await finishPersistentRun(
      pool,run.runId,'FAILED',
      {seen:1,succeeded:0,failed:1},e
    );
    console.error('r1d-dispatch-error',e);
    return true;
  }
}

let stopping=false;
process.on('SIGTERM',()=>{stopping=true;});
process.on('SIGINT',()=>{stopping=true;});

async function main(){
  while(!stopping){
    const didWork=await processOne().catch(e=>{
      console.error('r1d-worker-loop-error',e);
      return false;
    });
    if(!didWork) await sleep(jitter());
  }
  await pool.end();
}

main().catch(async e=>{
  console.error(e);
  await pool.end().catch(()=>undefined);
  process.exitCode=1;
});
