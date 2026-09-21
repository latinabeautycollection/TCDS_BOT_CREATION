import { Pool } from 'pg';
import { startPersistentRun,finishPersistentRun } from './provenance';
import { parseBrightDataZoneCost,validateDateRange } from './brightdata-financial';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [zone,from,toExclusive]=process.argv.slice(2);
const apiToken=process.env.BRIGHTDATA_API_TOKEN;
const actor=process.env.R1F_ACTOR_NAME||'R1F V2.2 Bright Data Financial Collector';

if(!zone||!from||!toExclusive){
  throw new Error('usage: tsx collect-brightdata-zone-cost.ts <zone> <from YYYY-MM-DD> <to-exclusive YYYY-MM-DD>');
}
if(!apiToken) throw new Error('BRIGHTDATA_API_TOKEN is required');
validateDateRange(from,toExclusive);

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1F_BRIGHTDATA_COST_COLLECT','worker',
    'r1f-v2.2-brightdata-cost-collector',actor,
    'retail.r1f_provider_cost_evidence','FINANCIAL_EVIDENCE'
  );
  try{
    const url=new URL('https://api.brightdata.com/zone/cost');
    url.searchParams.set('zone',zone);
    url.searchParams.set('from',from);
    url.searchParams.set('to',toExclusive);

    const response=await fetch(url,{
      method:'GET',
      headers:{
        Authorization:`Bearer ${apiToken}`,
        Accept:'application/json'
      }
    });
    const text=await response.text();
    let payload:unknown;
    try{ payload=JSON.parse(text); }
    catch{ throw new Error(`Bright Data returned non-JSON body (${response.status})`); }

    if(!response.ok){
      throw new Error(`Bright Data /zone/cost failed HTTP ${response.status}: ${text.slice(0,500)}`);
    }
    parseBrightDataZoneCost(payload);

    const result=await pool.query(`
      select retail.r1f_record_brightdata_zone_cost_response(
        $1,$2::date,$3::date,$4,$5::jsonb,$6,$7,$8
      ) evidence_id
    `,[
      zone,from,toExclusive,response.status,JSON.stringify(payload),
      run.runId,run.correlationId,actor
    ]);

    const evidenceId=result.rows[0].evidence_id;
    const count=(await pool.query(`
      select count(*)::int n
      from retail.r1f_provider_cost_buckets
      where evidence_id=$1
    `,[evidenceId])).rows[0].n;

    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:count,succeeded:count,failed:0},
      undefined,{evidenceId,zone,from,toExclusive,bucketCount:count}
    );

    console.log(JSON.stringify({
      event:'r1f_v22_brightdata_zone_cost_collected',
      evidenceId,zone,from,toExclusive,bucketCount:count
    },null,2));
  }catch(e){
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e)
      .catch(()=>undefined);
    throw e;
  }finally{
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
