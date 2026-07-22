import { config } from './config.js'; import { fetchWithRetry, HttpError } from './http.js'; import type { SnapshotStatus } from './types.js'; import { log } from './log.js';
const headers={Authorization:`Bearer ${config.BRIGHT_DATA_API_TOKEN}`,'Content-Type':'application/json'};
export async function triggerDataset(urls:string[]):Promise<string>{
 const endpoint=`https://api.brightdata.com/datasets/v3/trigger?dataset_id=${encodeURIComponent(config.LENOVO_DATASET_ID)}&notify=false&include_errors=true`;
 const r=await fetchWithRetry(endpoint,{method:'POST',headers,body:JSON.stringify({input:urls.map(url=>({url})),limit_per_input:config.LENOVO_LIMIT_PER_INPUT})});
 const j=await r.json() as SnapshotStatus; const id=j.snapshot_id??j.id; if(!id)throw new Error(`Bright Data trigger returned no snapshot_id: ${JSON.stringify(j)}`); return id;
}
export async function waitForSnapshot(id:string):Promise<void>{
 const start=Date.now();
 while(Date.now()-start<config.SNAPSHOT_MAX_WAIT_MS){
  try{const r=await fetchWithRetry(`https://api.brightdata.com/datasets/v3/progress/${encodeURIComponent(id)}`,{headers:{Authorization:headers.Authorization}},3);const j=await r.json() as SnapshotStatus;const s=(j.status??'').toLowerCase();log('info','snapshot_status',{snapshotId:id,status:s});if(['ready','done','completed','success'].includes(s))return;if(['failed','error','cancelled','canceled'].includes(s))throw new Error(`Snapshot ${id} terminal status ${s}: ${JSON.stringify(j.error??j)}`);}catch(e){if(e instanceof HttpError&&e.status===404&&Date.now()-start<60000){log('warn','snapshot_not_visible_yet',{snapshotId:id});}else throw e;}
  await new Promise(r=>setTimeout(r,config.SNAPSHOT_POLL_INTERVAL_MS));
 }
 throw new Error(`Snapshot ${id} exceeded max wait ${config.SNAPSHOT_MAX_WAIT_MS}ms`);
}
export async function downloadSnapshot(id:string):Promise<unknown[]>{
 const r=await fetchWithRetry(`https://api.brightdata.com/datasets/v3/snapshot/${encodeURIComponent(id)}?format=json`,{headers:{Authorization:headers.Authorization}},6);
 const text=await r.text(); if(!text.trim())return [];
 try{const j=JSON.parse(text);return Array.isArray(j)?j:[j];}catch{const rows=text.split(/\r?\n/).filter(Boolean).map((line,i)=>{try{return JSON.parse(line);}catch{throw new Error(`Invalid JSONL at line ${i+1}`);}});return rows;}
}
