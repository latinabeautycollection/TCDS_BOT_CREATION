import {createHash} from 'node:crypto';
export function canonical(v:any):string{if(v===null||typeof v!=='object')return JSON.stringify(v);if(Array.isArray(v))return '['+v.map(canonical).join(',')+']';return '{'+Object.keys(v).sort().map(k=>JSON.stringify(k)+':'+canonical(v[k])).join(',')+'}'}
export function sha256Canonical(v:any):string{return createHash('sha256').update(canonical(v)).digest('hex')}
export function sha256Text(v:string):string{return createHash('sha256').update(v).digest('hex')}
