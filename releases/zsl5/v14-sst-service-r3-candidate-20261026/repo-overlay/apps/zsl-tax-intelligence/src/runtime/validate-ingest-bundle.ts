import {readFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {Ajv2020} from 'ajv/dist/2020.js';
import {canonicalJson,sha256} from '../core/hash.js';

const files:Record<string,string>={TAX_REGIME:'tax-regime',TAX_JURISDICTION:'tax-jurisdiction',TAX_JURISDICTION_ASSIGNMENT:'jurisdiction',STATE_RATE:'state-rate',LOCAL_RATE:'local-rate',RATE_COMPONENT_RULE:'rate-component-rule',RATE_CAP_THRESHOLD_RULE:'rate-cap-threshold-rule',PRODUCT_TAXABILITY:'taxability',TAXABLE_BASE_RULE:'taxable-base',BUNDLED_TRANSACTION_RULE:'bundled-transaction-rule',ALLOCATION_RULE:'allocation-rule',TAX_HOLIDAY:'holiday',SOURCING_RULE:'sourcing',SELLER_COLLECTION_RULE:'seller-collection-rule',MARKETPLACE_RULE:'marketplace',SELLER_TAX_ELECTION:'seller-tax-election',EXEMPTION_RULE:'exemption',EXEMPTION_CERTIFICATE_REQUIREMENT:'exemption-certificate-requirement',TAX_CREDIT_RULE:'tax-credit',ROUNDING_RULE:'rounding-rule',MANDATORY_TRANSACTION_FEE:'mandatory-transaction-fee'};
const uuid=(v:unknown)=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
function instant(v:string){return /(?:Z|[+-]\d{2}:\d{2})$/i.test(v)&&Number.isFinite(Date.parse(v));}

// Validate the entire batch before opening a transaction or issuing writes.
export async function validateIngestBundle(b:any):Promise<void>{
 if(!b||typeof b!=='object'||Array.isArray(b))throw new Error('BUNDLE_OBJECT_REQUIRED');
 for(const k of ['releaseId','artifactId','ingestRunId'])if(!uuid(b[k]))throw new Error('INVALID_'+k);
 for(const k of ['sourceKey','releaseKey'])if(typeof b[k]!=='string'||!b[k].trim())throw new Error('MISSING_'+k);
 if(!Array.isArray(b.records)||!b.records.length||b.records.length>2000000)throw new Error('INVALID_RECORD_COUNT');
 const ajv=new Ajv2020({allErrors:true,strict:false});
 ajv.addFormat('date-time',{type:'string',validate:instant});
 const validators=new Map<string,ReturnType<typeof ajv.compile>>();
 const identities=new Set<string>();
 for(let i=0;i<b.records.length;i++){
  const r=b.records[i],doc=r?.record;
  if(!r||!doc||typeof doc!=='object'||Array.isArray(doc))throw new Error('RECORD_OBJECT_REQUIRED:'+i);
  const name=files[r.family];if(!name)throw new Error('UNKNOWN_TAX_FAMILY:'+i);
  if(!validators.has(r.family)){
   const schema=JSON.parse(await readFile(resolve('apps/zsl-tax-intelligence/schemas',name+'.schema.json'),'utf8'));
   validators.set(r.family,ajv.compile(schema));
  }
  if(!validators.get(r.family)!(doc))throw new Error('CANONICAL_SCHEMA_VALIDATION_FAILED:'+i);
  if(doc.source_key!==b.sourceKey)throw new Error('SOURCE_IDENTITY_MISMATCH:'+i);
  if(doc.source_release_id!==b.releaseId)throw new Error('RELEASE_IDENTITY_MISMATCH:'+i);
  const fields=[['family','record_type'],['stateCode','state_code'],['naturalKey','natural_key'],['authorityRank','authority_rank'],['parserVersion','parser_version'],['normalizationVersion','normalization_version']];
  for(const [outer,inner] of fields)if(r[outer!]!==doc[inner!])throw new Error('RECORD_ENVELOPE_MISMATCH:'+outer+':'+i);
  for(const [outer,inner] of [['publishedAt','published_at'],['effectiveFrom','effective_from'],['effectiveTo','effective_to'],['legalCitation','legal_citation']])
   if((r[outer!]??null)!==(doc[inner!]??null))throw new Error('RECORD_INTERVAL_OR_CITATION_MISMATCH:'+i);
  if(doc.effective_from&&doc.effective_to&&Date.parse(doc.effective_to)<=Date.parse(doc.effective_from))throw new Error('INVALID_EFFECTIVE_INTERVAL:'+i);
  const h=sha256(canonicalJson(doc));
  if(r.recordSha256!==undefined&&r.recordSha256!==h)throw new Error('RECORD_SHA_MISMATCH:'+i);
  if(identities.has(r.naturalKey))throw new Error('DUPLICATE_NATURAL_KEY:'+i);
  identities.add(r.naturalKey);
 }
}
