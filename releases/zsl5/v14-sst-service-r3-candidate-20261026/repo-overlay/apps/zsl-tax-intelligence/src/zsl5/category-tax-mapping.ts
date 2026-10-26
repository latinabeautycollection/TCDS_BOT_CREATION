import type {PoolClient} from 'pg';
import {readFile} from 'node:fs/promises';
import {sha256} from '../core/hash.js';

export async function loadCategoryTaxonomy(c:PoolClient,buildRunId:string){
  const t=JSON.parse(await readFile(new URL('../../config/tax-product-taxonomy.json',import.meta.url),'utf8'));
  const build=(await c.query(`select engine_version from zsl.zsl5_build_runs where build_run_id=$1`,[buildRunId])).rows[0];
  if(!build||build.engine_version!=='zsl5-v1.4.0')throw new Error('ZSL5_V14_BUILD_REQUIRED_FOR_CATEGORY_TAXONOMY');
  const prior=(await c.query(`select distinct mapping_version from zsl.zsl5_tax_product_mappings_v14 where build_run_id=$1`,[buildRunId])).rows.map((x:any)=>String(x.mapping_version));
  if(prior.some((v:string)=>v!==t.version))throw new Error('CATEGORY_TAXONOMY_VERSION_COLLISION:'+prior.join(','));
  let n=0;
  for(const [category,v] of Object.entries<any>(t.businessCategories)){
    const doc={category,taxProductClass:v.default_tax_product_class,subclasses:v.subclasses,requiresRefinement:Boolean(v.requires_refinement),version:t.version,authorityName:t.authorityName};
    await c.query(`insert into zsl.zsl5_tax_product_mappings_v14(build_run_id,tcds_category_code,tax_product_class,tax_product_subclass,attribute_predicate,mapping_confidence,mapping_version,mapping_document,mapping_sha256,enabled)
                   values($1,$2,$3,NULL,'{}'::jsonb,1,$4,$5::jsonb,$6,true) on conflict do nothing`,
      [buildRunId,category,v.default_tax_product_class,t.version,JSON.stringify(doc),sha256(doc)]);
    n++;
  }
  if(n!==10)throw new Error('TEN_CATEGORY_TAXONOMY_REQUIRED');
  return n;
}
