import { createHash } from 'node:crypto';
import { readFile,stat } from 'node:fs/promises';
import path from 'node:path';

const root=path.resolve(process.argv[2]||process.env.R1E_PACKAGE_ROOT||process.cwd());

const sha=async(file:string)=>
  createHash('sha256').update(await readFile(file)).digest('hex');

async function main(){
  const manifest=JSON.parse(
    await readFile(path.join(root,'MANIFEST.sha256.json'),'utf8')
  ) as Record<string,string>;

  const mismatches:any[]=[];
  for(const [rel,expected] of Object.entries(manifest)){
    const file=path.join(root,rel);
    try{
      const s=await stat(file);
      if(!s.isFile()) throw new Error('not a file');
      const observed=await sha(file);
      if(observed!==expected){
        mismatches.push({file:rel,expected,observed});
      }
    }catch(e){
      mismatches.push({
        file:rel,error:String((e as Error).message??e)
      });
    }
  }

  const pass=mismatches.length===0;
  console.log(JSON.stringify({
    event:'r1e_package_manifest_verification',
    files:Object.keys(manifest).length,
    pass,mismatches
  },null,2));
  if(!pass) process.exitCode=2;
}

main().catch(e=>{console.error(e);process.exitCode=1;});
