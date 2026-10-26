import { readFile,writeFile,mkdir } from 'node:fs/promises';import { URL } from 'node:url';import { join } from 'node:path';
const keywords:Record<string,RegExp>={
  TAX_REGIME:/sales tax|use tax|gross receipts|excise|transaction privilege|general excise/i,
  TAX_JURISDICTION:/tax jurisdiction|taxing jurisdiction|tax district|location code|special district/i,
  TAX_JURISDICTION_ASSIGNMENT:/lookup|address|jurisdiction|gis|boundary|zip.?4|location code/i,
  STATE_RATE:/sales.{0,20}tax.{0,20}rate|state rate/i,
  LOCAL_RATE:/local|county|city|district|surtax/i,
  RATE_COMPONENT_RULE:/combined rate|rate component|state.*county.*city|local option/i,
  RATE_CAP_THRESHOLD_RULE:/cap|threshold|single article|max(?:imum)?.*tax|bracket/i,
  PRODUCT_TAXABILITY:/taxable|exempt|taxability/i,
  TAXABLE_BASE_RULE:/shipping|delivery|handling|coupon|rebate|trade.?in|sales price/i,
  BUNDLED_TRANSACTION_RULE:/bundled transaction|bundle/i,
  ALLOCATION_RULE:/allocation|allocate.*shipping|allocate.*discount|mixed taxable/i,
  TAX_HOLIDAY:/holiday/i,
  SOURCING_RULE:/sourcing|destination|origin|receipt location/i,
  SELLER_COLLECTION_RULE:/remote seller|economic nexus|collection threshold|nexus/i,
  MARKETPLACE_RULE:/marketplace|facilitator/i,
  SELLER_TAX_ELECTION:/election|single local rate|remote seller election/i,
  EXEMPTION_RULE:/resale|exemption/i,
  EXEMPTION_CERTIFICATE_REQUIREMENT:/certificate|blanket certificate|resale certificate|exemption form/i,
  TAX_CREDIT_RULE:/credit.*tax|tax.*credit|use tax credit/i,
  ROUNDING_RULE:/rounding|tax computation/i,
  MANDATORY_TRANSACTION_FEE:/retail delivery fee|recycling fee|mandatory fee|environmental fee/i
};
function links(html:string,base:string){const out=new Set<string>();const re=/href\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))/gi;for(const m of html.matchAll(re)){const raw=(m[1]??m[2]??m[3]??'').replace(/&amp;/g,'&');try{const u=new URL(raw,base);if(['http:','https:'].includes(u.protocol))out.add(u.href);}catch{}}return [...out];}
function sameAuthority(url:string,host:string){try{const h=new URL(url).hostname.replace(/^www\./,'');return h===host||h.endsWith('.'+host)||host.endsWith('.'+h);}catch{return false;}}
async function get(url:string){const r=await fetch(url,{headers:{'user-agent':'TCDS-ZSL1-NationalTaxAcquisition/1.1'}});if(!r.ok)throw new Error(`HTTP_${r.status}`);return {url:r.url,html:await r.text()};}
async function main(){const arg=(n:string)=>{const i=process.argv.indexOf(n);return i>=0?process.argv[i+1]:undefined};const state=(arg('--state')??'').toUpperCase();const j=JSON.parse(await readFile('catalog/jurisdictions-51.json','utf8'));await mkdir('data/discovery',{recursive:true});for(const s of j.jurisdictions.filter((x:any)=>!state||x.state_code===state)){try{const first=await get(s.authority_root_url);const host=new URL(first.url).hostname.replace(/^www\./,'');const firstLinks=links(first.html,first.url).filter(x=>sameAuthority(x,host));const relevantFirst=firstLinks.filter(x=>Object.values(keywords).some(re=>re.test(x))).slice(0,40);const discovered=new Set(firstLinks);for(const u of relevantFirst.slice(0,12)){try{const p=await get(u);for(const l of links(p.html,p.url))if(sameAuthority(l,host))discovered.add(l);}catch{}}const ls=[...discovered];const candidates:any={state_code:s.state_code,authority_root_url:s.authority_root_url,retrieved_at:new Date().toISOString(),families:{}};for(const [f,re] of Object.entries(keywords))candidates.families[f]=ls.filter(x=>re.test(x)).slice(0,40);await writeFile(join('data/discovery',`${s.state_code}.json`),JSON.stringify(candidates,null,2)+'\n');}catch(e){await writeFile(join('data/discovery',`${s.state_code}.json`),JSON.stringify({state_code:s.state_code,error:String(e)},null,2)+'\n');}}}
main().catch(e=>{console.error(e);process.exitCode=1});
