import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [kind,id,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1D_ACTOR_NAME||'R1D Policy Authority';

const tableByKind:Record<string,string>={
  budget:'retail.r1d_budget_policies',
  schedule:'retail.r1d_schedule_policies',
  cost:'retail.r1d_cost_profiles'
};

if(!tableByKind[kind]||!id){
  throw new Error(
    'usage: tsx deactivate-policy.ts <budget|schedule|cost> <uuid> [actor]'
  );
}

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1D_POLICY_CONFIG','user',actor,actor,tableByKind[kind]
  );
  try{
    const q=`update ${tableByKind[kind]} set active=false,updated_at=now()
             where id=$1 and active=true returning id`;
    const r=await pool.query(q,[id]);
    if(!r.rowCount) throw new Error('active policy not found');

    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0}
    );
    console.log(JSON.stringify({
      event:'r1d_policy_deactivated',kind,id,processRunId:run.runId
    },null,2));
  }catch(e){
    await finishPersistentRun(
      pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e
    );
    throw e;
  }finally{
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
