import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {spawn} from 'node:child_process';

type StatePlan={state_code:string;wave:number};type Plan={states:StatePlan[]};
const arg=(n:string)=>{const i=process.argv.indexOf(n);return i>=0?process.argv[i+1]:undefined};const has=(n:string)=>process.argv.includes(n);
const plan=JSON.parse(await readFile(resolve(arg('--plan')??'apps/zsl-tax-intelligence/catalog/state-source-execution-plan.json'),'utf8')) as Plan;
const wave=Number(arg('--wave')??'0');const only=new Set((arg('--states')??'').split(',').map(x=>x.trim()).filter(Boolean));const selected=plan.states.filter(s=>(!wave||s.wave===wave)&&(!only.size||only.has(s.state_code)));
if(has('--plan-only')){console.log(JSON.stringify({count:selected.length,states:selected.map(x=>x.state_code)},null,2));process.exit(0)}
function run(cmd:string,args:string[],cwd:string){return new Promise<number>((ok,fail)=>{const p=spawn(cmd,args,{cwd,stdio:'inherit',env:process.env});p.on('error',fail);p.on('close',c=>ok(c??1));});}
const toolRoot=resolve('tools/zsl-tax-source-acquisition');const receiptPath=resolve(arg('--receipt')??'runtime-evidence/source-acquisition-run.json');await mkdir(dirname(receiptPath),{recursive:true});const results:any[]=[];const started=new Date().toISOString();
// First acquire the configured national/SST/state machine-readable sources.
const dl=await run(process.execPath,['--import','tsx','acquisition/downloader.ts','--config','config/sources/tax-sources.json','--out',resolve('runtime-evidence/raw')],toolRoot);results.push({stage:'configured-downloads',exit_code:dl});
if(dl!==0&&!has('--continue-on-error')){await writeFile(receiptPath,JSON.stringify({started_at:started,results},null,2)+'\n');process.exit(2)}
// Then discover state-specific legal/rule sources only on official authority domains.
for(const s of selected){const code=await run(process.execPath,['--import','tsx','acquisition/state-source-discovery.ts','--state',s.state_code],toolRoot);results.push({stage:'state-discovery',state_code:s.state_code,wave:s.wave,exit_code:code});if(code!==0&&!has('--continue-on-error'))break;}
const receipt={schema_version:'1.0.0',started_at:started,completed_at:new Date().toISOString(),selected_states:selected.map(x=>x.state_code),results};await writeFile(receiptPath,JSON.stringify(receipt,null,2)+'\n');if(results.some(x=>x.exit_code!==0))process.exitCode=1;
