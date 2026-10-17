import fs from'node:fs';import path from'node:path';import{sha256Text}from'../core/hash.js';
export function migrationManifest(){
 const p=path.resolve(process.cwd(),'evidence','MIGRATION_MANIFEST.json');
 if(!fs.existsSync(p))throw new Error('ZSL3_MIGRATION_MANIFEST_MISSING');
 const raw=fs.readFileSync(p,'utf8'),entries=JSON.parse(raw);
 if(!Array.isArray(entries))throw new Error('ZSL3_MIGRATION_MANIFEST_INVALID');
 return{entries,sha256:sha256Text(raw)};
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
