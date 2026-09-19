import { Pool,PoolClient } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL,max:5});
const intervalMs=Number(process.env.R1D_SCHEDULER_INTERVAL_MS??'60000');
const materializeLimit=Number(process.env.R1D_MATERIALIZE_LIMIT??'500');
const actor=process.env.R1D_ACTOR_NAME||'R1D Scheduler Service';

if(!Number.isInteger(intervalMs)||intervalMs<5000){
  throw new Error('R1D_SCHEDULER_INTERVAL_MS must be integer >= 5000');
}
if(!Number.isInteger(materializeLimit)||materializeLimit<1||materializeLimit>10000){
  throw new Error('R1D_MATERIALIZE_LIMIT must be integer 1..10000');
}

const sleep=(ms:number)=>new Promise(r=>setTimeout(r,ms));
let stopping=false;
let leader:PoolClient|undefined;
let leadershipValid=false;

function clearLeadership(reason:string){
  if(leadershipValid){
    console.error(JSON.stringify({event:'r1d_scheduler_leadership_lost',reason}));
  }
  leadershipValid=false;
  if(leader){
    try{leader.release(true);}catch{}
    leader=undefined;
  }
}

async function tryLeader(){
  if(leader) clearLeadership('reacquire');
  const c=await pool.connect();

  const onError=(e:Error)=>clearLeadership(`connection_error:${e.message}`);
  const onEnd=()=>clearLeadership('connection_end');
  c.on('error',onError);
  // pg PoolClient does not guarantee a public 'end' event, but underlying
  // connection does.
  (c as any).connection?.once?.('end',onEnd);

  try{
    const r=await c.query(`
      select pg_try_advisory_lock(
        hashtextextended('r1d-scheduler-leader',0)
      ) leader
    `);
    if(r.rows[0]?.leader===true){
      leader=c;
      leadershipValid=true;
      return true;
    }
    c.release();
    return false;
  }catch(e){
    c.release(true);
    throw e;
  }
}

async function proveLeadership(){
  if(!leader||!leadershipValid) return false;
  try{
    // Session-local advisory lock count is visible in pg_locks for this backend.
    const r=await leader.query(`
      select exists(
        select 1
        from pg_locks
        where locktype='advisory'
          and pid=pg_backend_pid()
          and granted
      ) ok
    `);
    if(r.rows[0]?.ok!==true){
      clearLeadership('advisory_lock_missing');
      return false;
    }
    return true;
  }catch(e){
    clearLeadership(`leadership_probe_failed:${String((e as Error).message??e)}`);
    return false;
  }
}

async function cycle(){
  if(!(await proveLeadership())){
    throw new Error('scheduler cycle blocked: leadership not proven');
  }

  const run=await startPersistentRun(
    pool,'RETAIL_R1D_MATERIALIZE','service_account',
    'r1d-scheduler-service',actor,'retail.r1d_dispatch_jobs'
  );

  try{
    const stale=await pool.query(`
      select retail.r1d_reconcile_stale_jobs($1,$2) reconciled
    `,[run.runId,run.correlationId]);

    const sync=await pool.query(`
      select retail.r1d_sync_schedule_state_v2(now(),$1,$2) synchronized
    `,[run.runId,run.correlationId]);

    const mat=await pool.query(`
      select retail.r1d_materialize_due_jobs_v2(
        now(),$1,$2,$3,$4
      ) materialized
    `,[materializeLimit,run.runId,run.correlationId,actor]);

    const reap=await pool.query(`
      select retail.r1d_reap_expired_leases(now(),$1,$2) reaped
    `,[run.runId,run.correlationId]);

    const report={
      reconciled:Number(stale.rows[0].reconciled),
      synchronized:Number(sync.rows[0].synchronized),
      materialized:Number(mat.rows[0].materialized),
      reaped:Number(reap.rows[0].reaped)
    };

    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {
        seen:report.synchronized,
        succeeded:report.materialized,
        failed:0
      },
      undefined,report
    );

    console.log(JSON.stringify({
      event:'r1d_scheduler_cycle',
      ...report,
      processRunId:run.runId
    }));
  }catch(e){
    await finishPersistentRun(pool,run.runId,'FAILED',{},e);
    throw e;
  }
}

async function shutdown(){
  if(stopping) return;
  stopping=true;
  try{
    if(leader&&leadershipValid){
      await leader.query(`
        select pg_advisory_unlock(
          hashtextextended('r1d-scheduler-leader',0)
        )
      `).catch(()=>undefined);
    }
  }finally{
    clearLeadership('shutdown');
    await pool.end();
  }
}

process.on('SIGTERM',()=>void shutdown());
process.on('SIGINT',()=>void shutdown());

async function main(){
  while(!stopping){
    if(!leadershipValid){
      const won=await tryLeader().catch(e=>{
        console.error('leader-election-error',e);
        return false;
      });
      if(!won){
        await sleep(intervalMs);
        continue;
      }
      console.log(JSON.stringify({event:'r1d_scheduler_leader_acquired'}));
    }

    try{
      await cycle();
    }catch(e){
      console.error('r1d-scheduler-cycle-error',e);
    }

    await sleep(intervalMs);
  }
}

main().catch(async e=>{
  console.error(e);
  await shutdown();
  process.exitCode=1;
});
