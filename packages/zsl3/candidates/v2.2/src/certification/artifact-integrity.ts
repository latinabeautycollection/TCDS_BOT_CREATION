import fs from'node:fs';import path from'node:path';import{sha256Canonical,sha256Text}from'../core/hash.js';
export function migrationManifest(){
 const dir=path.resolve(process.cwd(),'database','migrations');
 const files=fs.readdirSync(dir).filter((f:string)=>f.endsWith('.sql')).sort();
 const entries=files.map((f:string)=>({file:f,sha256:sha256Text(fs.readFileSync(path.join(dir,f),'utf8'))}));
 return{entries,sha256:sha256Text(JSON.stringify(entries))};
}
export function dependencyLockEvidence(){
 const p=path.resolve(process.cwd(),'package-lock.json');if(!fs.existsSync(p))return{ok:false,reason:'MISSING_LOCK',sha256:null,missing:[]};
 const raw=fs.readFileSync(p,'utf8'),j=JSON.parse(raw),packages=j.packages??{},missing:string[]=[];
 for(const [k,v] of Object.entries<any>(packages)){if(k==='')continue;if(!v?.version)missing.push(`${k}:version`);if(!v?.resolved)missing.push(`${k}:resolved`);if(!v?.integrity)missing.push(`${k}:integrity`)}
 return{ok:missing.length===0,sha256:sha256Text(raw),missing};
}
export function sourceManifestEvidence(){
 const p=path.resolve(process.cwd(),'evidence','SOURCE_MANIFEST.json');if(!fs.existsSync(p))return{ok:false,sha256:null};
 const raw=fs.readFileSync(p,'utf8');return{ok:true,sha256:sha256Text(raw)};
}
