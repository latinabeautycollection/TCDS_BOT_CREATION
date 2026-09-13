import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [routeId,compileMode,additionalRequiredCsv,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1C_ACTOR_NAME||'R1C Profile Service';

if(!routeId||!compileMode){
  throw new Error(
    'usage: tsx create-compile-profile.ts <route_uuid> <keyword|category|product_url|store_inventory> [additional_required_fields_csv] [actor]'
  );
}
const additional=(additionalRequiredCsv||'')
  .split(',').map(x=>x.trim()).filter(Boolean);

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1C_PROFILE_CREATE','service_account',
    'r1c-profile',actor,'retail.search_route_compile_profiles'
  );

  const c=await pool.connect();
  try{
    await c.query('begin');
    const policy={
      dedupe:'token_case_insensitive',
      stable_order:true
    };

    const x=await c.query(`
      select retail.r1c_create_compile_profile(
        $1,$2,$3::jsonb,$4::jsonb,$5,$6,$7
      ) id
    `,[
      routeId,compileMode,JSON.stringify(additional),
      JSON.stringify(policy),actor,run.runId,run.correlationId
    ]);

    await c.query('commit');
    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});

    console.log(JSON.stringify({
      event:'r1c_v3_compile_profile_created',
      profileId:x.rows[0].id,
      processRunId:run.runId,
      correlationId:run.correlationId,
      additionalRequiredFields:additional
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e);
    throw e;
  }finally{
    c.release();await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
