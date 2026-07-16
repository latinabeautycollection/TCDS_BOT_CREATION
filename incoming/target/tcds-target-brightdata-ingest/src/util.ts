import crypto from 'node:crypto';
export const sleep=(ms:number)=>new Promise(r=>setTimeout(r,ms));
export function stableStringify(value:unknown):string { if(value===null||typeof value!=='object') return JSON.stringify(value); if(Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`; const o=value as Record<string,unknown>; return `{${Object.keys(o).sort().map(k=>`${JSON.stringify(k)}:${stableStringify(o[k])}`).join(',')}}`; }
export const sha256=(v:unknown)=>crypto.createHash('sha256').update(typeof v==='string'?v:stableStringify(v)).digest('hex');
export function parseMoney(v:unknown):number|null { if(typeof v==='number'&&Number.isFinite(v)) return v; if(typeof v!=='string') return null; const n=Number(v.replace(/[^0-9.-]/g,'')); return Number.isFinite(n)?n:null; }
export const cleanText=(v:unknown)=>typeof v==='string'?v.replace(/<br\s*\/?>/gi,'\n').replace(/<[^>]+>/g,' ').replace(/\s+/g,' ').trim():null;
export function retryDelay(attempt:number,retryAfterMs?:number){ if(retryAfterMs&&retryAfterMs>0)return Math.min(retryAfterMs,120000); const cap=Math.min(1000*2**(attempt-1),60000); return Math.floor(cap/2+Math.random()*cap/2); }
export function errorInfo(e:unknown){ return e instanceof Error?{name:e.name,message:e.message,stack:e.stack}:{name:'UnknownError',message:String(e)}; }
