import { config } from './config.js';
import { log } from './log.js';

export class HttpError extends Error { constructor(public status:number, public body:string, public url:string, public retryable:boolean, public retryAfterMs?:number){super(`HTTP ${status} for ${url}`);} }
const RETRYABLE=new Set([408,425,429,500,502,503,504]);
const sleep=(ms:number)=>new Promise(r=>setTimeout(r,ms));
function retryAfter(h:string|null):number|undefined{if(!h)return;const n=Number(h);if(Number.isFinite(n))return Math.max(0,n*1000);const d=Date.parse(h);return Number.isNaN(d)?undefined:Math.max(0,d-Date.now());}
export async function fetchWithRetry(url:string,init:RequestInit={},attempts=config.HTTP_MAX_ATTEMPTS):Promise<Response>{
  let last:unknown;
  for(let attempt=1;attempt<=attempts;attempt++){
    const c=new AbortController(); const t=setTimeout(()=>c.abort(),config.HTTP_TIMEOUT_MS);
    try{
      const r=await fetch(url,{...init,signal:c.signal});
      if(r.ok)return r;
      const body=(await r.text()).slice(0,10000); const ra=retryAfter(r.headers.get('retry-after')); const retryable=RETRYABLE.has(r.status);
      const err=new HttpError(r.status,body,url,retryable,ra);
      if(!retryable||attempt===attempts)throw err;
      last=err;
    }catch(e){
      last=e;
      const retryable=e instanceof HttpError?e.retryable:(e instanceof DOMException&&e.name==='AbortError')||e instanceof TypeError;
      if(!retryable||attempt===attempts)throw e;
    }finally{clearTimeout(t);}
    const base=last instanceof HttpError&&last.retryAfterMs!==undefined?last.retryAfterMs:Math.min(30000,500*2**(attempt-1));
    const delay=Math.round(base*(0.75+Math.random()*0.5)); log('warn','http_retry',{url,attempt,delay,error:String(last)}); await sleep(delay);
  }
  throw last;
}
