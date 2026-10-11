import {readdir,readFile,stat,writeFile} from 'node:fs/promises';
import {join,relative} from 'node:path';
import {createHash} from 'node:crypto';
const root=process.cwd();
const ignored=new Set(['evidence/SOURCE_MANIFEST.json','evidence/SOURCE_MANIFEST_SHA256.txt']);
const ignoredDirs=new Set(['node_modules','dist','.git']);
const files=[];
async function walk(dir){for(const name of (await readdir(dir)).sort()){const abs=join(dir,name);const rel=relative(root,abs).replaceAll('\\','/');const s=await stat(abs);if(s.isDirectory()){if(!ignoredDirs.has(name))await walk(abs);continue;}if(!s.isFile()||ignored.has(rel))continue;const b=await readFile(abs);files.push({path:rel,sha256:createHash('sha256').update(b).digest('hex'),bytes:b.length});}}
await walk(root);
const manifest={package:'TCDS_ZSL2_GREEN_TIER1_CANONICAL_GEOGRAPHY_V2_1_3_PERFORMANCE_REMEDIATION_FINAL_FREEZE_CANDIDATE',releaseVersion:'2.1.3',runtimeEngineCompatibility:'zsl2-v2.1.0',files};
const text=JSON.stringify(manifest,null,2)+'\n';await writeFile('evidence/SOURCE_MANIFEST.json',text);const sha=createHash('sha256').update(text).digest('hex');await writeFile('evidence/SOURCE_MANIFEST_SHA256.txt',`${sha}  evidence/SOURCE_MANIFEST.json\n`);console.log(`SOURCE_MANIFEST_GENERATED files=${files.length} sha256=${sha}`);
