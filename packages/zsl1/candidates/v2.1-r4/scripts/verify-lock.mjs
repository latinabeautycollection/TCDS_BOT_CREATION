#!/usr/bin/env node
import fs from 'node:fs';
const lock=JSON.parse(fs.readFileSync(new URL('../package-lock.json',import.meta.url),'utf8'));
const problems=[];
for(const [path,pkg] of Object.entries(lock.packages??{})){
  if(path==='') continue;
  if(!pkg || typeof pkg!=='object'){problems.push(`${path}:invalid-entry`);continue;}
  if(!pkg.version) problems.push(`${path}:missing-version`);
  // npm may omit resolved/integrity for local/link packages only. ZSL1 has none.
  if(!pkg.resolved) problems.push(`${path}:missing-resolved`);
  if(!pkg.integrity) problems.push(`${path}:missing-integrity`);
}
if(problems.length){
  console.error('DEPENDENCY_LOCK_NOT_FULLY_RESOLVED');
  for(const p of problems) console.error(p);
  process.exit(2);
}
console.log(`DEPENDENCY_LOCK_RESOLVED:${Object.keys(lock.packages).length-1}`);
