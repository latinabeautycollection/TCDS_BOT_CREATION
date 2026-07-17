import type { TriggerInput } from "../domain/types.js";

const PDP_PATHS = [
  /^\/.+\/p\/[^/?#]+\/?$/i,
  /^\/[^/?#]+\.html$/i
];

const decodeHtml = (value:string) => value
  .replace(/&amp;/gi, "&")
  .replace(/&#x2f;/gi, "/")
  .replace(/&#47;/gi, "/")
  .replace(/\\u002f/gi, "/")
  .replace(/\\\//g, "/");

export function isAdoramaProductUrl(raw:string):boolean {
  try {
    const url=new URL(decodeHtml(raw),"https://www.adorama.com");
    return /(^|\.)adorama\.com$/i.test(url.hostname) && PDP_PATHS.some(pattern=>pattern.test(url.pathname));
  } catch {
    return false;
  }
}

export function canonicalAdoramaProductUrl(raw:string):string|null {
  try {
    const url=new URL(decodeHtml(raw),"https://www.adorama.com");
    if(!isAdoramaProductUrl(url.href)) return null;
    url.protocol="https:";
    url.hostname="www.adorama.com";
    url.search="";
    url.hash="";
    return url.href;
  } catch {
    return null;
  }
}

export function extractAdoramaProductUrls(html:string):string[] {
  const urls=new Map<string,string>();
  const add=(value:string)=>{
    const canonical=canonicalAdoramaProductUrl(value);
    if(!canonical)return;
    const parsed=new URL(canonical);
    const productCode=parsed.pathname.match(/\/p\/([^/]+)\/?$/i)?.[1]?.toLowerCase();
    const key=productCode??parsed.pathname.toLowerCase();
    if(!urls.has(key))urls.set(key,canonical);
  };
  for(const match of html.matchAll(/\bhref\s*=\s*["']([^"']+)["']/gi)) add(match[1]??"");
  for(const match of html.matchAll(/https?:\\?\/\\?\/[^"'<>\s]+/gi)) add(match[0]??"");
  return [...urls.values()];
}

export async function discoverAdoramaInputs(
  seeds:string[],
  fetchHtml:(url:string)=>Promise<string>,
  maxRows:number
):Promise<TriggerInput[]> {
  const urls=new Map<string,string>();
  const add=(url:string)=>{
    const parsed=new URL(url);
    const productCode=parsed.pathname.match(/\/p\/([^/]+)\/?$/i)?.[1]?.toLowerCase();
    const key=productCode??parsed.pathname.toLowerCase();
    if(!urls.has(key))urls.set(key,url);
  };
  for(const seed of seeds){
    const direct=canonicalAdoramaProductUrl(seed);
    if(direct){add(direct);continue;}
    let discovered:string[]=[];
    for(let attempt=1;attempt<=3&&!discovered.length;attempt++){
      discovered=extractAdoramaProductUrls(await fetchHtml(seed));
      if(!discovered.length&&attempt<3)await new Promise(resolve=>setTimeout(resolve,attempt*1000));
    }
    for(const url of discovered){
      add(url);
      if(urls.size>=maxRows) return [...urls.values()].map(url=>({url}));
    }
  }
  if(!urls.size) throw new Error("ADORAMA_DISCOVERY_RETURNED_NO_PRODUCTS");
  return [...urls.values()].slice(0,maxRows).map(url=>({url}));
}
