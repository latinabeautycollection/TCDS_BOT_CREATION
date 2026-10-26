import {createHash} from 'node:crypto';
export function sha256(v:unknown):string{const s=typeof v==='string'?v:canonicalJson(v);return createHash('sha256').update(s).digest('hex')}
export function canonicalJson(v:unknown):string{
 if(v===undefined)return 'null';
 if(v===null||typeof v!=='object'){if(typeof v==='bigint')return JSON.stringify(v.toString());const s=JSON.stringify(v);if(s===undefined)throw new Error('UNSERIALIZABLE_CANONICAL_JSON');return s}
 if(Array.isArray(v))return '['+v.map(x=>x===undefined?'null':canonicalJson(x)).join(',')+']';
 const o=v as Record<string,unknown>;const keys=Object.keys(o).filter(k=>o[k]!==undefined).sort();return '{'+keys.map(k=>JSON.stringify(k)+':'+canonicalJson(o[k])).join(',')+'}'
}
