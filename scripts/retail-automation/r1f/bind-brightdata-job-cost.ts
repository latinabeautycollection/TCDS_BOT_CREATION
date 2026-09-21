import { Pool } from 'pg';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [authorityPeriodId,jobId,basis,explicitWeightArg]=process.argv.slice(2);
const actor=process.env.R1F_ACTOR_NAME||'R1F V2.2 Financial Reconciler';

if(!authorityPeriodId||!jobId||!basis){
  throw new Error(
    'usage: tsx bind-brightdata-job-cost.ts <authority_period_uuid> <r1d_job_uuid> '+
    '<DIRECT_RESOURCE|PROVIDER_BYTES|PROVIDER_REQUESTS|RECORDS_COLLECTED|RECORDS_REQUESTED|EQUAL_SHARE|EXPLICIT_WEIGHT> [weight]'
  );
}
const explicitWeight=explicitWeightArg?Number(explicitWeightArg):null;
if(explicitWeightArg && (!Number.isFinite(explicitWeight!)||explicitWeight!<=0)){
  throw new Error('explicit weight must be positive numeric');
}

async function main(){
  try{
    const q=await pool.query(`
      select retail.r1f_bind_job_to_provider_cost_period_v22(
        $1,$2,$3,$4::numeric,$5
      ) binding_id
    `,[authorityPeriodId,jobId,basis,explicitWeight,actor]);
    console.log(JSON.stringify({
      event:'r1f_v22_job_bound_to_provider_cost_period',
      authorityPeriodId,jobId,basis,bindingId:q.rows[0].binding_id
    },null,2));
  }finally{ await pool.end(); }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
