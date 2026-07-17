import fs from 'node:fs/promises';
import path from 'node:path';
import { config } from './config.js';
import { log } from './log.js';
import { triggerDataset,waitForSnapshot,downloadSnapshot } from './brightdata.js';
import { CostcoRecordSchema } from './types.js';
import { platformAndConfig,createRun,finishRun,deadLetter,ingestRecord,pool } from './db.js';
import { isCostcoUrl,normalizePrices,sha256,stableJson } from './util.js';
import { unlockCostcoPage } from './unlocker.js';
import { discoverCostcoInputs,extractCostcoPdpOffer } from './discovery.js';

async function localDlq(payload:unknown,code:string,error:unknown){await fs.mkdir(config.DLQ_DIRECTORY,{recursive:true});await fs.writeFile(path.join(config.DLQ_DIRECTORY,`${Date.now()}-${code}-${sha256(stableJson(payload)).slice(0,12)}.json`),JSON.stringify({ts:new Date().toISOString(),code,error:String(error),payload},null,2));}
async function mapLimit<T>(items:T[],limit:number,fn:(x:T)=>Promise<void>){let i=0;await Promise.all(Array.from({length:Math.min(limit,items.length)},async()=>{while(true){const n=i++;if(n>=items.length)return;await fn(items[n]!);}}));}
function providerError(raw:unknown):{code:string;message:string}|null{if(!raw||typeof raw!=='object')return null;const row=raw as Record<string,unknown>;if(!row.error&&!row.error_code)return null;return{code:`PROVIDER_${String(row.error_code??'unknown')}`,message:String(row.error??'Bright Data provider error')};}

async function main(){
 const badUrl=config.seedUrls.find(u=>!isCostcoUrl(u));if(badUrl)throw new Error(`Rejected non-Costco seed URL: ${badUrl}`);
 const inputs=await discoverCostcoInputs(config.seedUrls,async url=>(await unlockCostcoPage(url)).body,config.COSTCO_LIMIT_PER_INPUT);
 const urls=inputs.map(input=>input.url);
 const {platformId,configId}=await platformAndConfig();const runKey=`costco:${new Date().toISOString()}:${sha256(urls.join('|')).slice(0,12)}`;let runId='';const stats={collected:0,failed:0,skipped:0};
 try{runId=await createRun(platformId,configId,runKey,urls);log('info','costco_run_started',{runId,seeds:config.seedUrls,discovered:urls.length});
  const snapshotId=await triggerDataset(urls);log('info','dataset_triggered',{runId,snapshotId});await waitForSnapshot(snapshotId);const rows=await downloadSnapshot(snapshotId);log('info','snapshot_downloaded',{runId,snapshotId,rows:rows.length});
  if(rows.length===0)throw new Error('COSTCO_SNAPSHOT_EMPTY');
  await mapLimit(rows,config.INGEST_CONCURRENCY,async raw=>{const pe=providerError(raw);if(pe){stats.skipped++;await deadLetter(platformId,runId,raw,pe.code,pe.message,false);return;}const p=CostcoRecordSchema.safeParse(raw);if(!p.success){stats.failed++;await deadLetter(platformId,runId,raw,'VALIDATION_ERROR',p.error.message);await localDlq(raw,'VALIDATION_ERROR',p.error);return;}let record=p.data;if(normalizePrices(record.price,record.sale_price).effective==null){try{const unlocked=await unlockCostcoPage(record.url);const offer=extractCostcoPdpOffer(unlocked.body);if(!offer)throw new Error('No Product offer price found in unlocked PDP JSON-LD');record={...record,price:offer.price,sale_price:null,price_recovery:{source:'web_unlocker_jsonld',zone:unlocked.zone,currency:offer.currency}};log('info','costco_price_recovered',{runId,itemId:record.item_id,price:offer.price,zone:unlocked.zone});}catch(e){stats.failed++;await deadLetter(platformId,runId,record,'PRICE_RECOVERY_ERROR',String(e));await localDlq(record,'PRICE_RECOVERY_ERROR',e);return;}}try{await ingestRecord(platformId,runId,record);stats.collected++;}catch(e){stats.failed++;await deadLetter(platformId,runId,record,'INGEST_ERROR',String(e));await localDlq(record,'INGEST_ERROR',e);}});
  const status=stats.failed||stats.skipped?'partial':'completed';const reason=status==='partial'?`${stats.skipped} provider rows skipped; ${stats.failed} ingestion rows failed`:undefined;
  await finishRun(runId,status,stats,reason);log('info','costco_run_completed',{runId,...stats,status});
 }catch(e){if(runId)await finishRun(runId,'failed',stats,String(e));log('error','costco_run_failed',{runId,error:String(e),...stats});throw e;}finally{await pool.end();}
}
main().catch(()=>process.exitCode=1);
