import {readFile,stat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const root=new URL('../',import.meta.url);
const manifest=JSON.parse(await readFile(new URL('../evidence/SOURCE_MANIFEST.json',import.meta.url),'utf8'));
let bad=0;
for(const f of manifest.files){
  const u=new URL(`../${f.path}`,import.meta.url);
  const b=await readFile(u);const s=await stat(u);const h=createHash('sha256').update(b).digest('hex');
  if(h!==f.sha256||s.size!==f.bytes){console.error(`MISMATCH ${f.path}`);bad++;}
}
if(bad)process.exit(2);console.log(`SOURCE_MANIFEST_OK files=${manifest.files.length}`);
