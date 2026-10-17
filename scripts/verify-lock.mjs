import fs from'node:fs';
const pkg=JSON.parse(fs.readFileSync('package.json','utf8'));
const l=JSON.parse(fs.readFileSync('package-lock.json','utf8'));
if(!l.lockfileVersion)throw new Error('LOCK_MISSING');
const expected=[...Object.keys(pkg.dependencies??{}),...Object.keys(pkg.devDependencies??{})];
const missingDirect=[];
for(const name of expected){
  const e=l.packages?.[`node_modules/${name}`];
  if(!e||!e.version||!e.resolved||!e.integrity)missingDirect.push(name);
}
const unresolved=Object.entries(l.packages??{})
  .filter(([k,v])=>k&&(!v?.version||!v?.resolved||!v?.integrity))
  .map(([k])=>k);
if(missingDirect.length||unresolved.length){
  console.error(JSON.stringify({status:'LOCK_INCOMPLETE',missingDirect,unresolved},null,2));
  process.exit(2);
}
console.log('LOCK_OK');
