import crypto from 'node:crypto';
export const sha256=(v:string|Buffer)=>crypto.createHash('sha256').update(v).digest('hex');
export const stableJson=(v:unknown)=>JSON.stringify(v,(_k,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.keys(x).sort().reduce((o,k)=>(o[k]=x[k],o),{} as any):x);
export function money(v:unknown):number|null{if(v==null)return null;const n=typeof v==='number'?v:Number(String(v).replace(/[^0-9.-]/g,''));return Number.isFinite(n)&&n>=0?Math.round(n*100)/100:null;}
export function normalizePrices(priceValue:unknown,saleValue:unknown){const price=money(priceValue),alternate=money(saleValue);if(price==null&&alternate==null)return{regular:null,sale:null,effective:null};if(price==null||alternate==null){const only=price??alternate;return{regular:only,sale:null,effective:only};}const effective=Math.min(price,alternate),regular=Math.max(price,alternate);return{regular,sale:effective<regular?effective:null,effective};}
export function availability(v:string|null|undefined){const x=(v??'').toLowerCase();if(/in.?stock|available/.test(x))return 'in_stock';if(/out.?of.?stock|unavailable/.test(x))return 'out_of_stock';return 'unknown';}
export function isCostcoUrl(v:string){try{const u=new URL(v);return u.protocol==='https:'&&(u.hostname==='costco.com'||u.hostname.endsWith('.costco.com'));}catch{return false;}}
export function htmlLooks404(body:string){return /404|page not found|product not found|we could not find/i.test(body.slice(0,12000));}
