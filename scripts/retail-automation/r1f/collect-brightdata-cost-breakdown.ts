import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';
import {
  parseBrightDataCostBreakdown,
  validateDateRange
} from './brightdata-financial';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [dimension,from,toExclusive]=process.argv.slice(2);
const apiToken=process.env.BRIGHTDATA_API_TOKEN;
const actor=process.env.R1F_ACTOR_NAME||'R1F V2.2 Bright Data Cost Breakdown Collector';

const allowed=new Set(['web_apis','collectors','ws_api_snaps']);
if(!dimension||!from||!toExclusive){
  throw new Error('usage: tsx collect-brightdata-cost-breakdown.ts <web_apis|collectors|ws_api_snaps> <from YYYY-MM-DD> <to-exclusive YYYY-MM-DD>');
}
if(!allowed.has(dimension)) throw new Error(`unsupported dimension ${dimension}`);
if(!apiToken) throw new Error('BRIGHTDATA_API_TOKEN is required');
validateDateRange(from,toExclusive);

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1F_BRIGHTDATA_COST_BREAKDOWN_COLLECT','worker',
    'r1f-v2.2-cost-breakdown-collector',actor,
    'retail.r1f_provider_cost_breakdown_evidence','FINANCIAL_EVIDENCE'
  );
  try{
    const response=await fetch('https://api.brightdata.com/costs/export/json',{
      method:'POST',
      headers:{
        Authorization:`Bearer ${apiToken}`,
        Accept:'application/json',
        'Content-Type':'application/json'
      },
      body:JSON.stringify({
        dimension,
        filters:{},
        from,
        to:toExclusive
      })
    });
    const text=await response.text();
    let payload:unknown;
    try{ payload=JSON.parse(text); }
    catch{ throw new Error(`Bright Data returned non-JSON body (${response.status})`); }
    if(!response.ok){
      throw new Error(`Bright Data /costs/export/json failed HTTP ${response.status}: ${text.slice(0,500)}`);
    }
    parseBrightDataCostBreakdown(payload,from,toExclusive);

    const q=await pool.query(`
      select retail.r1f_record_brightdata_cost_breakdown_response(
        $1,$2::date,$3::date,$4,$5::jsonb,$6,$7,$8
      ) evidence_id
    `,[
      dimension,from,toExclusive,response.status,JSON.stringify(payload),
      run.runId,run.correlationId,actor
    ]);
    const evidenceId=q.rows[0].evidence_id;

    const counts=(await pool.query(`
      select
        count(*)::int resources,
        count(distinct cost_day)::int days
      from retail.r1f_provider_daily_resource_costs
      where evidence_id=$1
    `,[evidenceId])).rows[0];

    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:counts.resources,succeeded:counts.resources,failed:0},
      undefined,{evidenceId,dimension,from,toExclusive,...counts}
    );

    console.log(JSON.stringify({
      event:'r1f_v22_brightdata_cost_breakdown_collected',
      evidenceId,dimension,from,toExclusive,...counts
    },null,2));
  }catch(e){
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e)
      .catch(()=>undefined);
    throw e;
  }finally{ await pool.end(); }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
