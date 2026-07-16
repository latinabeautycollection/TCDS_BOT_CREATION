import { config } from './config.js'; import { fetchWithRetry } from './http.js';
export type UnlockResult={url:string,zone:string,body:string,contentType:string,status:number};
async function unlock(url:string,zone:string):Promise<UnlockResult>{const r=await fetchWithRetry('https://api.brightdata.com/request',{method:'POST',headers:{Authorization:`Bearer ${config.BRIGHT_DATA_API_TOKEN}`,'Content-Type':'application/json'},body:JSON.stringify({zone,url,format:'raw'})});return {url,zone,body:await r.text(),contentType:r.headers.get('content-type')??'text/html',status:r.status};}
function zones(){return config.STAPLES_UNLOCKER_ZONE_POLICY==='premium_only'?[config.BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE]:config.STAPLES_UNLOCKER_ZONE_POLICY==='standard_only'?[config.BRIGHT_DATA_UNLOCKER_ZONE]:[config.BRIGHT_DATA_UNLOCKER_ZONE,config.BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE];}
export async function unlockStaplesPage(url:string){let last:unknown;for(const zone of zones()){try{return await unlock(url,zone);}catch(e){last=e;}}throw last;}

function decodeHtml(value:string){return value.replace(/&amp;/gi,'&').replace(/&#x2f;/gi,'/').replace(/&#47;/g,'/').replace(/&quot;/gi,'"').replace(/&#39;/g,"'");}
export function extractStaplesProductUrls(html:string,baseUrl:string){const urls=new Set<string>();const add=(raw:string)=>{try{const u=new URL(decodeHtml(raw).replace(/\\u002f/gi,'/').replace(/\\\//g,'/'),baseUrl);if(!/(^|\.)staples\.com$/i.test(u.hostname)||!/\/product_\d+\/?$/i.test(u.pathname))return;u.hash='';u.search='';urls.add(u.href);}catch{}};for(const m of html.matchAll(/\bhref\s*=\s*["']([^"']+)["']/gi))add(m[1]??'');for(const m of html.matchAll(/https?:\\?\/\\?\/[^"'<>\s]+\/product_\d+/gi))add(m[0]??'');return [...urls];}
export async function discoverStaplesPage(url:string,maxRows:number){
  let last:unknown;
  for(const zone of zones()){
    for(let attempt=1;attempt<=3;attempt++){
      try{
        const result=await unlock(url,zone);
        const productUrls=extractStaplesProductUrls(result.body,url).slice(0,maxRows);
        if(!productUrls.length){
          throw new Error(`STAPLES_DISCOVERY_EMPTY:${url}:${zone}:attempt=${attempt}`);
        }
        return {...result,productUrls};
      }catch(e){
        last=e;
        if(attempt<3){
          await new Promise(resolve=>setTimeout(resolve,2000*attempt));
        }
      }
    }
  }
  throw last;
}
export function parseStaplesJsonLd(html:string):Record<string,unknown>|null{const scripts=[...html.matchAll(/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)];for(const m of scripts){try{const j=JSON.parse(m[1]??'');const arr=Array.isArray(j)?j:[j];for(const x of arr){const nodes=x&&typeof x==='object'&&'@graph' in x&&Array.isArray((x as any)['@graph'])?(x as any)['@graph']:[x];const p=nodes.find((n:any)=>n?.['@type']==='Product');if(p)return p;}}catch{}}return null;}
