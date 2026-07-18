import crypto from 'node:crypto';
export const sha256=(v:string|Buffer)=>crypto.createHash('sha256').update(v).digest('hex');
export const stableJson=(v:unknown)=>JSON.stringify(v,(_k,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.keys(x).sort().reduce((o,k)=>(o[k]=x[k],o),{} as any):x);
export function money(v:unknown):number|null{if(v==null)return null;const n=typeof v==='number'?v:Number(String(v).replace(/[^0-9.-]/g,''));return Number.isFinite(n)&&n>=0?Math.round(n*100)/100:null;}
export function normalizePrices(price:unknown,salePrice:unknown){const first=money(price),second=money(salePrice);if(first===null&&second===null)return{regular:null,sale:null,effective:null};if(first===null||second===null){const only=first??second;return{regular:only,sale:null,effective:only};}if(first===second)return{regular:first,sale:null,effective:first};const regular=Math.max(first,second),sale=Math.min(first,second);return{regular,sale,effective:sale};}
export function availability(v:string|null|undefined){const x=(v??'').toLowerCase();if(/in.?stock|available/.test(x))return 'in_stock';if(/out.?of.?stock|unavailable/.test(x))return 'out_of_stock';return 'unknown';}
export function isNeweggUrl(v:string){try{const u=new URL(v);return u.protocol==='https:'&&(u.hostname==='newegg.com'||u.hostname.endsWith('.newegg.com'));}catch{return false;}}
export function htmlLooks404(body:string){return !body.trim()||/404|page not found|product not found|we could not find/i.test(body.slice(0,12000));}
