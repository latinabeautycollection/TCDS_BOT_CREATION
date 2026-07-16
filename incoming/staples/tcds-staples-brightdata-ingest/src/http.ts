import { config } from './config.js'; import { retryDelay, sleep } from './util.js';
export class HttpError extends Error { constructor(public status:number, public body:string, public retryAfterMs?:number){super(`HTTP ${status}: ${body.slice(0,500)}`);} }
const retryable=new Set([408,425,429,500,502,503,504]);
export async function fetchWithRetry(url:string,init:RequestInit={},attempts=config.MAX_HTTP_ATTEMPTS):Promise<Response>{
 let last:unknown; for(let i=1;i<=attempts;i++){ const c=new AbortController(); const t=setTimeout(()=>c.abort(),config.HTTP_TIMEOUT_MS); try{ const r=await fetch(url,{...init,signal:c.signal}); if(r.ok)return r; const body=await r.text(); const ra=r.headers.get('retry-after'); const ms=ra?(Number.isFinite(Number(ra))?Number(ra)*1000:Math.max(0,Date.parse(ra)-Date.now())):undefined; const err=new HttpError(r.status,body,ms); if(!retryable.has(r.status)||i===attempts)throw err; last=err; }catch(e){last=e;if(i===attempts)throw e;}finally{clearTimeout(t);} await sleep(retryDelay(i,last instanceof HttpError?last.retryAfterMs:undefined)); } throw last;
}
