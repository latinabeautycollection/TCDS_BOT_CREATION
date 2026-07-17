const decodeHtml = (value:string) => value
  .replace(/&amp;/gi, "&")
  .replace(/&#x2f;/gi, "/")
  .replace(/&#47;/gi, "/")
  .replace(/\\u002f/gi, "/")
  .replace(/\\\//g, "/");

export function canonicalBhPhotoProductUrl(raw:string):string|null {
  try {
    const url=new URL(decodeHtml(raw),"https://www.bhphotovideo.com");
    if(!/(^|\.)bhphotovideo\.com$/i.test(url.hostname)) return null;
    if(!/^\/c\/product\/\d+(?:-[^/]+)?\/[^/?#]+\.html$/i.test(url.pathname)) return null;
    url.protocol="https:";
    url.hostname="www.bhphotovideo.com";
    url.search="";
    url.hash="";
    return url.href;
  } catch {
    return null;
  }
}

export function extractBhPhotoProductUrls(html:string):string[] {
  const byId=new Map<string,string>();
  const add=(value:string)=>{const canonical=canonicalBhPhotoProductUrl(value);const id=canonical?.match(/\/c\/product\/(\d+)/i)?.[1];if(canonical&&id&&!byId.has(id))byId.set(id,canonical)};
  for(const match of html.matchAll(/\bhref\s*=\s*["']([^"']+)["']/gi)) add(match[1]??"");
  for(const match of html.matchAll(/https?:\\?\/\\?\/[^"'<>\s]+/gi)) add(match[0]??"");
  return [...byId.values()];
}

export function extractBhPhotoPaginationUrls(html:string,seed:string):string[] {
  const urls=new Map<number,string>();
  for(const match of html.matchAll(/\bhref\s*=\s*["']([^"']+)["']/gi)){
    try{
      const url=new URL(decodeHtml(match[1]??""),seed);
      if(!/(^|\.)bhphotovideo\.com$/i.test(url.hostname))continue;
      const page=Number(url.pathname.match(/\/pn\/(\d+)\/?$/i)?.[1]);
      if(!Number.isInteger(page)||page<2)continue;
      url.protocol="https:";
      url.hostname="www.bhphotovideo.com";
      url.hash="";
      if(!urls.has(page))urls.set(page,url.href);
    }catch{}
  }
  return [...urls.entries()].sort(([a],[b])=>a-b).map(([,url])=>url);
}

export async function discoverBhPhotoInputs(
  seeds:Array<{url:string}>,
  fetchHtml:(url:string)=>Promise<string>,
  maxRows:number
):Promise<Array<{url:string}>> {
  const byId=new Map<string,string>();
  for(const seed of seeds){
    const direct=canonicalBhPhotoProductUrl(seed.url);
    if(direct){
      const id=direct.match(/\/c\/product\/(\d+)/i)?.[1];
      if(id&&!byId.has(id))byId.set(id,direct);
      if(byId.size>=maxRows)return [...byId.values()].map(url=>({url}));
      continue;
    }

    const pending=[seed.url];
    const visited=new Set<string>();
    while(pending.length&&byId.size<maxRows){
      const pageUrl=pending.shift()!;
      if(visited.has(pageUrl))continue;
      visited.add(pageUrl);

      let html="";
      let discovered:string[]=[];
      for(let attempt=1;attempt<=3&&!discovered.length;attempt++){
        html=await fetchHtml(pageUrl);
        discovered=extractBhPhotoProductUrls(html);
        if(!discovered.length&&attempt<3)await new Promise(resolve=>setTimeout(resolve,attempt*1000));
      }
      for(const url of discovered){
        const id=url.match(/\/c\/product\/(\d+)/i)?.[1];
        if(id&&!byId.has(id))byId.set(id,url);
        if(byId.size>=maxRows)return [...byId.values()].map(url=>({url}));
      }
      for(const next of extractBhPhotoPaginationUrls(html,pageUrl)){
        if(!visited.has(next)&&!pending.includes(next))pending.push(next);
      }
    }
  }
  if(!byId.size) throw new Error("BHPHOTO_DISCOVERY_RETURNED_NO_PRODUCTS");
  return [...byId.values()].slice(0,maxRows).map(url=>({url}));
}
