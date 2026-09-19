import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [configFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1D_ACTOR_NAME||'R1D Rate Policy Authority';
if(!configFile) throw new Error('usage: tsx set-rate-policy.ts <config.json> [actor]');

async function main(){
  const x=JSON.parse(await readFile(configFile,'utf8'));
  const run=await startPersistentRun(
    pool,'RETAIL_R1D_RATE_POLICY_CONFIG','user',actor,actor,
    'retail.r1d_rate_policies'
  );
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','user',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[actor]);
    await c.query(`select set_config('app.process_run_id',$1,true)`,[run.runId]);
    await c.query(`select set_config('app.correlation_id',$1,true)`,[run.correlationId]);

    const r=await c.query(`
      insert into retail.r1d_rate_policies(
        platform_id,hourly_limit,daily_limit,
        hourly_unlimited,daily_unlimited,active,created_by
      ) values($1,$2,$3,$4,$5,true,$6)
      on conflict(platform_id) do update set
        hourly_limit=excluded.hourly_limit,
        daily_limit=excluded.daily_limit,
        hourly_unlimited=excluded.hourly_unlimited,
        daily_unlimited=excluded.daily_unlimited,
        active=true,updated_at=now()
      returning *
    `,[
      x.platform_id,x.hourly_limit??null,x.daily_limit??null,
      !!x.hourly_unlimited,!!x.daily_unlimited,actor
    ]);

    await c.query('commit');
    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});
    console.log(JSON.stringify({
      event:'r1d_rate_policy_configured',
      policy:r.rows[0],processRunId:run.runId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e);
    throw e;
  }finally{c.release();await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
