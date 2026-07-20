import crypto from 'node:crypto';
export const sha256=(v:string|Buffer)=>crypto.createHash('sha256').update(v).digest('hex');
export const stableJson=(v:unknown)=>JSON.stringify(v,(_k,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.keys(x).sort().reduce((o,k)=>(o[k]=x[k],o),{} as any):x);
export function money(v:unknown):number|null{if(v==null)return null;const n=typeof v==='number'?v:Number(String(v).replace(/[^0-9.-]/g,''));return Number.isFinite(n)&&n>=0?Math.round(n*100)/100:null;}
export function normalizeLowesPrices(...inputs:unknown[]){
 const values=inputs.map(money).filter((value):value is number=>value!==null);
 if(!values.length)return {regular:null,sale:null,effective:null};
 const regular=Math.max(...values),effective=Math.min(...values);
 return {regular,sale:effective<regular?effective:null,effective};
}
export function availability(v:string|null|undefined){const x=(v??'').toLowerCase();if(/out.?of.?stock|unavailable/.test(x))return 'out_of_stock';if(/in.?stock|available/.test(x))return 'in_stock';return 'unknown';}
export function isLowesUrl(v:string){try{const u=new URL(v);return u.protocol==='https:'&&(u.hostname==='lowes.com'||u.hostname.endsWith('.lowes.com'));}catch{return false;}}
export function htmlLooks404(body:string){const head=body.slice(0,12000);return /<title[^>]*>\s*(?:404|page not found)|<h1[^>]*>\s*(?:404|page not found)|we could not find (?:that|this) page/i.test(head);}
