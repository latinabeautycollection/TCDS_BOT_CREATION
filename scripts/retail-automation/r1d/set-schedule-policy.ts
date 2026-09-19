import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [configFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1D_ACTOR_NAME||'R1D Schedule Authority';
if(!configFile) throw new Error('usage: tsx set-schedule-policy.ts <config.json> [actor]');

async function main(){
  const x=JSON.parse(await readFile(configFile,'utf8'));
  const run=await startPersistentRun(
    pool,'RETAIL_R1D_POLICY_CONFIG','user',actor,actor,
    'retail.r1d_schedule_policies'
  );
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','user',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[actor]);
    await c.query(`select set_config('app.process_run_id',$1,true)`,[run.runId]);
    await c.query(`select set_config('app.correlation_id',$1,true)`,[run.correlationId]);

    const r=await c.query(`
      insert into retail.r1d_schedule_policies(
        policy_code,platform_id,location_type,min_interval_seconds,
        initially_active,max_parallel,max_attempts,
        base_backoff_seconds,max_backoff_seconds,lease_seconds,
        priority,active,created_by
      ) values(
        $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,true,$12
      )
      returning *
    `,[
      x.policy_code,x.platform_id??null,x.location_type??null,
      x.min_interval_seconds,x.initially_active??false,
      x.max_parallel??1,x.max_attempts??5,
      x.base_backoff_seconds??60,x.max_backoff_seconds??21600,
      x.lease_seconds??900,x.priority??100,actor
    ]);

    await c.query('commit');
    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});
    console.log(JSON.stringify({
      event:'r1d_schedule_policy_created',
      policy:r.rows[0],processRunId:run.runId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e);
    throw e;
  }finally{c.release();await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
