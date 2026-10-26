import type {PoolClient} from 'pg';
import type {QuoteLine} from '../core/types.js';

export interface GovernedTaxProduct {
  taxProductClass:string;
  taxProductSubclass?:string;
  mappingId:string;
  mappingSha256:string;
}

function str(v:unknown){return typeof v==='string'&&v.trim()?v.trim():undefined}

export async function resolveTaxProductV14(c:PoolClient,buildRunId:string,line:QuoteLine):Promise<GovernedTaxProduct>{
  const q=await c.query(`
    select mapping_id,tax_product_class,tax_product_subclass,attribute_predicate,mapping_document,mapping_sha256
      from zsl.zsl5_tax_product_mappings_v14
     where build_run_id=$1 and tcds_category_code=$2 and enabled=true
     order by tax_product_subclass nulls first,mapping_id`,[buildRunId,line.tcdsCategoryCode]);
  if(!q.rowCount) throw new Error('TAX_PRODUCT_MAPPING_MISSING:'+line.tcdsCategoryCode);
  const defaultRows=q.rows.filter((r:any)=>r.tax_product_subclass==null);
  if(defaultRows.length!==1) throw new Error('TAX_PRODUCT_MAPPING_AMBIGUOUS:'+line.tcdsCategoryCode+':'+defaultRows.length);
  const d=defaultRows[0];
  const allowed=Array.isArray(d.mapping_document?.subclasses)?d.mapping_document.subclasses.map(String):[];
  const requiresRefinement=Boolean(d.mapping_document?.requiresRefinement??d.mapping_document?.requires_refinement);
  const requestedClass=str(line.taxProductClass);
  const requestedSubclass=str(line.taxProductSubclass)??str(line.attributes?.taxProductSubclass)??str(line.attributes?.productType);
  if(requestedClass && requestedClass!==d.tax_product_class){
    throw new Error(`CALLER_TAX_CLASS_MISMATCH:${line.lineId}:${requestedClass}:${d.tax_product_class}`);
  }
  if(requestedSubclass && allowed.length && !allowed.includes(requestedSubclass)){
    throw new Error(`TAX_PRODUCT_SUBCLASS_UNAUTHORIZED:${line.lineId}:${requestedSubclass}`);
  }
  if(requiresRefinement && !requestedSubclass){
    throw new Error('TAX_PRODUCT_CLASS_REFINEMENT_REQUIRED:'+line.lineId+':'+line.tcdsCategoryCode);
  }
  return {
    taxProductClass:String(d.tax_product_class),
    taxProductSubclass:requestedSubclass,
    mappingId:String(d.mapping_id),
    mappingSha256:String(d.mapping_sha256)
  };
}
