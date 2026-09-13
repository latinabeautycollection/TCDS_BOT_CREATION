import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [assetId,configFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1B_ACTOR_NAME||'R1B Adapter Authority';
if(!assetId||!configFile){
  throw new Error('usage: tsx create-adapter-for-scraper.ts <scraper_asset_uuid> <adapter-config.json> [actor]');
}

async function main(){
  const cfg=JSON.parse(await readFile(configFile,'utf8'));
  for(const k of ['adapter_type','adapter_code','adapter_version']){
    if(!cfg[k]) throw new Error(`missing adapter config field: ${k}`);
  }

  const c=await pool.connect();
  try{
    await c.query('begin');
    const s=await c.query(`
      select * from retail.retail_scraper_assets
      where id=$1 and discovery_status='verified'
    `,[assetId]);
    if(!s.rowCount) throw new Error('verified scraper asset required');
    const asset=s.rows[0];

    const r=await c.query(`
      insert into retail.retail_search_adapters(
        platform_id,adapter_type,adapter_code,adapter_version,
        implementation_ref,implementation_sha256,git_commit_sha,
        supports_keyword_search,supports_product_url,supports_category_search,
        supports_store_id,supports_postal_code,supports_region,supports_result_limit,
        supported_collection_methods,supports_all_collection_methods,
        supported_source_types,supports_all_source_types,
        input_contract_json,input_contract_sha256,
        capability_json,capability_sha256,
        certification_status,created_by,scraper_asset_id
      ) values(
        $1,$2,$3,$4,$5,$6,$7,
        $8,$9,$10,$11,$12,$13,$14,
        $15::jsonb,$16,$17::jsonb,$18,
        $19::jsonb,repeat('0',64),
        '{}'::jsonb,repeat('0',64),
        'uncertified',$20,$21
      ) returning id,adapter_code,adapter_version
    `,[
      asset.platform_id,cfg.adapter_type,cfg.adapter_code,cfg.adapter_version,
      asset.implementation_root,
      asset.implementation_authority_type==='package_tree'
        ? asset.package_tree_sha256
        : (asset.entrypoint_sha256??asset.package_tree_sha256),
      asset.git_commit_sha,
      !!cfg.supports_keyword_search,!!cfg.supports_product_url,
      !!cfg.supports_category_search,!!cfg.supports_store_id,
      !!cfg.supports_postal_code,!!cfg.supports_region,
      !!cfg.supports_result_limit,
      JSON.stringify(cfg.supported_collection_methods??[]),
      !!cfg.supports_all_collection_methods,
      JSON.stringify(cfg.supported_source_types??[]),
      !!cfg.supports_all_source_types,
      JSON.stringify(cfg.input_contract_json??{}),
      actor,assetId
    ]);
    await c.query('commit');
    console.log(JSON.stringify({
      event:'r1b_adapter_created_for_existing_scraper',
      scraperAssetId:assetId,
      adapter:r.rows[0]
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    throw e;
  }finally{
    c.release();await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
