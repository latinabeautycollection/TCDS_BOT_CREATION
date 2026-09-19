import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [configFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1D_ACTOR_NAME||'R1D Budget Authority';
if(!configFile) throw new Error('usage: tsx set-budget-policy.ts <config.json> [actor]');

async function main(){
  const x=JSON.parse(await readFile(configFile,'utf8'));
  const period=x.period_kind??'DAILY';
  if(!['DAILY','MONTHLY'].includes(period)){
    throw new Error('period_kind must be DAILY or MONTHLY');
  }

  const run=await startPersistentRun(
    pool,'RETAIL_R1D_POLICY_CONFIG','user',actor,actor,
    'retail.r1d_budget_policies'
  );
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','user',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[actor]);
    await c.query(`select set_config('app.process_run_id',$1,true)`,[run.runId]);
    await c.query(`select set_config('app.correlation_id',$1,true)`,[run.correlationId]);

    const r=await c.query(`
      insert into retail.r1d_budget_policies(
        policy_code,scope_type,platform_id,collection_source_id,
        daily_limit_usd,budget_timezone,period_kind,active,effective_from,
        effective_until,created_by
      ) values(
        $1,$2,$3,$4,$5,'UTC',$6,true,
        coalesce($7::timestamptz,now()),$8::timestamptz,$9
      )
      returning *
    `,[
      x.policy_code,x.scope_type,x.platform_id??null,
      x.collection_source_id??null,x.daily_limit_usd,period,
      x.effective_from??null,x.effective_until??null,actor
    ]);
    await c.query('commit');
    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});
    console.log(JSON.stringify({event:'r1d_v2_budget_policy_created',policy:r.rows[0],processRunId:run.runId},null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e);
    throw e;
  }finally{c.release();await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
