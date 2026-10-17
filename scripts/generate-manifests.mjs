import fs from'node:fs';import path from'node:path';import crypto from'node:crypto';
const root=process.cwd();
const skip=new Set([
 'STATIC_IMPLEMENTATION_CERTIFICATION.json','evidence/SOURCE_MANIFEST.json','evidence/SOURCE_MANIFEST_SHA256.txt',
 'evidence/MIGRATION_MANIFEST.json','evidence/MIGRATION_MANIFEST_SHA256.txt','evidence/MIGRATION_SHA256.txt'
]);
const walk=d=>fs.readdirSync(d,{withFileTypes:true}).flatMap(e=>{const p=path.join(d,e.name);return e.isDirectory()?walk(p):[p]});
const files=walk(root).map(p=>path.relative(root,p)).filter(p=>!skip.has(p)&&!p.startsWith('dist/')&&!p.includes('node_modules')).sort();
const sh=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const m=files.map(p=>({path:p,sha256:sh(path.join(root,p))}));
fs.mkdirSync('evidence',{recursive:true});
fs.writeFileSync('evidence/SOURCE_MANIFEST.json',JSON.stringify(m));
const raw=fs.readFileSync('evidence/SOURCE_MANIFEST.json');fs.writeFileSync('evidence/SOURCE_MANIFEST_SHA256.txt',crypto.createHash('sha256').update(raw).digest('hex')+'\n');
const mig=m.filter(x=>x.path.startsWith('database/migrations/'));
fs.writeFileSync('evidence/MIGRATION_MANIFEST.json',JSON.stringify(mig));
const migRaw=fs.readFileSync('evidence/MIGRATION_MANIFEST.json');fs.writeFileSync('evidence/MIGRATION_MANIFEST_SHA256.txt',crypto.createHash('sha256').update(migRaw).digest('hex')+'\n');
fs.writeFileSync('evidence/MIGRATION_SHA256.txt',mig.map(x=>x.sha256+'  '+x.path).join('\n')+'\n');
