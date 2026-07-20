import crypto from 'node:crypto';
export const sha256=(v:string|Buffer)=>crypto.createHash('sha256').update(v).digest('hex');
export const stableJson=(v:unknown)=>JSON.stringify(v,(_k,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.keys(x).sort().reduce((o,k)=>(o[k]=x[k],o),{} as any):x);
export function money(v:unknown):number|null{if(v==null)return null;const n=typeof v==='number'?v:Number(String(v).replace(/[^0-9.-]/g,''));return Number.isFinite(n)&&n>=0?Math.round(n*100)/100:null;}
export function normalizePrices(price:unknown,salePrice:unknown){const a=money(price),b=money(salePrice);if(a===null&&b===null)return {regular:null,sale:null,effective:null};if(a===null)return {regular:b,sale:null,effective:b};if(b===null||a===b)return {regular:a,sale:null,effective:a};const regular=Math.max(a,b),sale=Math.min(a,b);return {regular,sale,effective:sale};}
export function availability(v:string|null|undefined){const x=(v??'').toLowerCase();if(/in.?stock|available/.test(x))return 'in_stock';if(/out.?of.?stock|unavailable/.test(x))return 'out_of_stock';return 'unknown';}
export function isOfficeDepotUrl(v:string){try{const u=new URL(v);return u.protocol==='https:'&&(u.hostname==='officedepot.com'||u.hostname.endsWith('.officedepot.com'));}catch{return false;}}
export function htmlLooks404(body:string){return /404|page not found|product not found|we could not find/i.test(body.slice(0,12000));}
