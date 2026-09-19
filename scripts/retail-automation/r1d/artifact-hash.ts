import { createHash } from 'node:crypto';
import { readFile,readdir,stat } from 'node:fs/promises';
import path from 'node:path';

const IGNORE=new Set(['node_modules','.git','dist','build','coverage']);

export async function shaFile(file:string){
  return createHash('sha256').update(await readFile(file)).digest('hex');
}

export async function walkTree(root:string):Promise<string[]>{
  const out:string[]=[];
  async function go(p:string){
    for(const name of (await readdir(p)).sort()){
      if(IGNORE.has(name)) continue;
      const full=path.join(p,name);
      const s=await stat(full);
      if(s.isDirectory()) await go(full);
      else if(s.isFile()) out.push(full);
    }
  }
  await go(root);
  return out;
}

export async function shaPackageTree(root:string){
  const files=await walkTree(root);
  const h=createHash('sha256');
  for(const f of files){
    const rel=path.relative(root,f).replaceAll(path.sep,'/');
    h.update(rel); h.update('\0');
    h.update(await readFile(f)); h.update('\0');
  }
  return {sha256:h.digest('hex'),files};
}

export async function attestableSha(
  authorityType:'file'|'package_tree',
  target:string
){
  if(authorityType==='file') return shaFile(target);
  return (await shaPackageTree(target)).sha256;
}
