import fs from 'node:fs';
const lock=JSON.parse(fs.readFileSync('package-lock.json','utf8'));
const failures=[];
for(const [k,v] of Object.entries(lock.packages??{})){
 if(!k) continue;
 if(!v.resolved || !v.integrity) failures.push(`${k}: missing resolved/integrity`);
}
if(failures.length){console.error('DEPENDENCY_LOCK_NOT_FULLY_RESOLVED');for(const x of failures)console.error(x);process.exit(2)}
console.log('DEPENDENCY_LOCK_FULLY_RESOLVED');
