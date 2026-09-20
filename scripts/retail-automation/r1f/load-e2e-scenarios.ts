import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [file,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1F_ACTOR_NAME||'R1F V2 E2E Scenario Loader';

if(!file){
  throw new Error('usage: tsx load-e2e-scenarios.ts <scenarios.json> [actor]');
}

async function main(){
  const scenarios=JSON.parse(await readFile(file,'utf8'));
  if(!Array.isArray(scenarios)){
    throw new Error('scenario file must be a JSON array');
  }

  const c=await pool.connect();
  let inserted=0;
  try{
    await c.query('begin');

    for(const s of scenarios){
      for(const k of [
        'scenario_code','scenario_type','job_ids','intelligence_policy_id','window_end',
        'expected_minimum_facts','expected_minimum_snapshots',
        'expected_minimum_recommendations'
      ]){
        if(!(k in s)){
          throw new Error(`scenario ${s.scenario_code??'?'} missing ${k}`);
        }
      }

      if(!Array.isArray(s.job_ids)||s.job_ids.length<2){
        throw new Error(`${s.scenario_code}: job_ids must contain at least 2 jobs`);
      }

      const jobs=await c.query(`
        select id,status
        from retail.r1d_dispatch_jobs
        where id=any($1::uuid[])
      `,[s.job_ids]);

      if(jobs.rowCount!==s.job_ids.length){
        throw new Error(`${s.scenario_code}: all R1D QA jobs must exist`);
      }

      if(jobs.rows.some(x=>x.status!=='succeeded')){
        throw new Error(`${s.scenario_code}: every R1D QA job must be succeeded`);
      }

      const policy=await c.query(`
        select 1
        from retail.r1f_intelligence_policies
        where id=$1 and certification_status='certified'
      `,[s.intelligence_policy_id]);

      if(!policy.rowCount){
        throw new Error(`${s.scenario_code}: certified intelligence policy required`);
      }

      await c.query(`
        insert into retail.r1f_e2e_qa_scenarios(
          scenario_code,scenario_type,job_ids,intelligence_policy_id,window_end,
          expected_top_location_fingerprint,
          expected_minimum_facts,
          expected_minimum_snapshots,
          expected_minimum_recommendations,
          fixture_sha256,active,created_by
        ) values(
          $1,$2,$3::uuid[],$4,$5::timestamptz,$6,$7,$8,$9,
          repeat('0',64),true,$10
        )
      `,[
        s.scenario_code,
        s.scenario_type,
        s.job_ids,
        s.intelligence_policy_id,
        s.window_end,
        s.expected_top_location_fingerprint??null,
        s.expected_minimum_facts,
        s.expected_minimum_snapshots,
        s.expected_minimum_recommendations,
        actor
      ]);

      inserted++;
    }

    await c.query('commit');
    console.log(JSON.stringify({
      event:'r1f_v2_e2e_scenarios_loaded',
      inserted
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}

main().catch(e=>{console.error(e);process.exitCode=1;});
