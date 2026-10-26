import type {PoolClient} from 'pg';import type {QuoteInput} from '../core/types.js';
function addCodes(h:Set<string>,v:any){const codes=Array.isArray(v.jurisdiction_codes)?v.jurisdiction_codes:[v.jurisdiction_code];for(const c of codes)if(typeof c==='string'&&c.trim())h.add(c.trim())}
export async function resolveJurisdictionsV14(c:PoolClient,buildRunId:string,i:QuoteInput):Promise<string[]>{
 const q=await c.query(`select fact_id,value_document from zsl.zsl5_family_facts_v14 where build_run_id=$1 and family='TAX_JURISDICTION_ASSIGNMENT' and state_code=$2 and (effective_from is null or effective_from<=$3::timestamptz) and (effective_to is null or effective_to>$3::timestamptz) order by priority,fact_id`,[buildRunId,i.stateCode,i.transactionDate]);
 const methods:[string,string|undefined][]=[['DIRECT_TAX_ADDRESS_ID',i.taxAddressId],['ZIP9',i.zip9]];
 for(const [method,value] of methods){if(!value)continue;const hits=new Set<string>();for(const r of q.rows){const v=r.value_document??{};if(v.assignment_method===method&&String(v.assignment_value??'')===String(value))addCodes(hits,v)}if(hits.size)return [...hits].sort()}
 // ADDRESS_RULE is source-governed exact/prefix matching; no inference beyond declared rule.
 {const hits=new Set<string>();for(const r of q.rows){const v=r.value_document??{};if(v.assignment_method!=='ADDRESS_RULE')continue;const p=v.predicate??{};const zip5Ok=!p.zip5||p.zip5===i.zip5;const zip9PrefixOk=!p.zip9_prefix||(i.zip9??'').startsWith(String(p.zip9_prefix));const addressIdOk=!p.tax_address_id||p.tax_address_id===i.taxAddressId;if(zip5Ok&&zip9PrefixOk&&addressIdOk)addCodes(hits,v)}if(hits.size)return [...hits].sort()}
 {const hits=new Set<string>();if(i.zsl2LocationId)for(const r of q.rows){const v=r.value_document??{};if(v.assignment_method==='DIRECT_ZSL2_ID'&&String(v.assignment_value??'')===i.zsl2LocationId)addCodes(hits,v)}if(hits.size)return [...hits].sort()}
 // AUTHORITATIVE_POLYGON only when coordinates are explicitly supplied and source geometry exists.
 if(Number.isFinite(i.latitude)&&Number.isFinite(i.longitude)){
   const p=await c.query(`select value_document from zsl.zsl5_family_facts_v14 where build_run_id=$1 and family='TAX_JURISDICTION_ASSIGNMENT' and state_code=$2 and value_document->>'assignment_method'='AUTHORITATIVE_POLYGON' and value_document ? 'geometry_geojson' and ST_Covers(ST_SetSRID(ST_GeomFromGeoJSON(value_document->>'geometry_geojson'),4326),ST_SetSRID(ST_MakePoint($3,$4),4326))`,[buildRunId,i.stateCode,i.longitude,i.latitude]);const hits=new Set<string>();for(const r of p.rows)addCodes(hits,r.value_document);if(hits.size)return [...hits].sort();
 }
 for(const [method,value] of [['ZIP5',i.zip5],['STATEWIDE',i.stateCode]] as [string,string|undefined][]){if(!value)continue;const hits=new Set<string>();for(const r of q.rows){const v=r.value_document??{};if(v.assignment_method===method&&String(v.assignment_value??'')===String(value))addCodes(hits,v)}if(hits.size)return [...hits].sort()}
 throw new Error('ZSL5_V14_JURISDICTION_UNRESOLVED');
}
