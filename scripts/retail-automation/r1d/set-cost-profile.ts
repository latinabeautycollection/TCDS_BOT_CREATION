import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [configFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1D_ACTOR_NAME||'R1D Cost Policy Authority';
if(!configFile) throw new Error('usage: tsx set-cost-profile.ts <config.json> [actor]');

async function main(){
  const x=JSON.parse(await readFile(configFile,'utf8'));
  if(!(Number(x.max_execution_cost_usd)>=0)){
    throw new Error('max_execution_cost_usd is required and must be nonnegative');
  }
  const run=await startPersistentRun(
    pool,'RETAIL_R1D_POLICY_CONFIG','user',actor,actor,
    'retail.r1d_cost_profiles'
  );
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','user',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[actor]);
    await c.query(`select set_config('app.process_run_id',$1,true)`,[run.runId]);
    await c.query(`select set_config('app.correlation_id',$1,true)`,[run.correlationId]);

    const r=await c.query(`
      insert into retail.r1d_cost_profiles(
        platform_id,collection_source_id,collection_method,cost_version,
        unit_type,unit_cost_usd,fixed_cost_usd,safety_multiplier,
        maximum_reservation_usd,cost_model_json,max_execution_cost_usd,
        active,evidence_json,evidence_sha256,created_by
      ) values(
        $1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11,
        true,$12::jsonb,repeat('0',64),$13
      )
      returning *
    `,[
      x.platform_id,x.collection_source_id??null,x.collection_method,
      x.cost_version,x.unit_type,x.unit_cost_usd,
      x.fixed_cost_usd??0,x.safety_multiplier??1.15,
      x.maximum_reservation_usd??null,
      JSON.stringify(x.cost_model_json??{}),
      x.max_execution_cost_usd,
      JSON.stringify(x.evidence??{}),actor
    ]);
    await c.query('commit');
    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});
    console.log(JSON.stringify({event:'r1d_v2_cost_profile_created',profile:r.rows[0],processRunId:run.runId},null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e);
    throw e;
  }finally{c.release();await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
