import {createHash} from 'node:crypto';
export function canonicalJson(value:unknown):string{
  const rec=(v:unknown):unknown=>Array.isArray(v)?v.map(rec):v&&typeof v==='object'&&!ArrayBuffer.isView(v)?Object.fromEntries(Object.entries(v as Record<string,unknown>).sort(([a],[b])=>a.localeCompare(b)).map(([k,x])=>[k,rec(x)])):v;
  return JSON.stringify(rec(value));
}
export function sha256Text(s:string):string{return createHash('sha256').update(s,'utf8').digest('hex');}
export function sha256Json(v:unknown):string{return sha256Text(canonicalJson(v));}
