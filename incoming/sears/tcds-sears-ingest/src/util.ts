import crypto from 'node:crypto';
export const sha256=(v:string|Buffer)=>crypto.createHash('sha256').update(v).digest('hex');
export const stableJson=(v:unknown)=>JSON.stringify(v,(_k,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.keys(x).sort().reduce((o,k)=>(o[k]=x[k],o),{} as any):x);
export function money(v:unknown):number|null{if(v==null)return null;const n=typeof v==='number'?v:Number(String(v).replace(/[^0-9.-]/g,''));return Number.isFinite(n)&&n>=0?Math.round(n*100)/100:null;}
export function availability(v:string|null|undefined){const x=(v??'').toLowerCase();if(/out.?of.?stock|currently unavailable|unavailable|not available/.test(x))return 'out_of_stock';if(/in.?stock|available/.test(x))return 'in_stock';return 'unknown';}
export function isSearsUrl(v:string){try{const u=new URL(v);return u.protocol==='https:'&&(u.hostname==='sears.com'||u.hostname.endsWith('.sears.com'));}catch{return false;}}
export function htmlLooks404(body:string){return /404|page not found|product not found|we could not find|no longer available/i.test(body.slice(0,16000));}
