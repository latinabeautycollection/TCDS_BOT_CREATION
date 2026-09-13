import { Pool } from 'pg';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [sourceAdapterId,newVersion,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1B_ACTOR_NAME||'R1B Adapter Version Authority';
if(!sourceAdapterId||!newVersion){
  throw new Error('usage: tsx clone-adapter-for-scraper-authority.ts <source_adapter_uuid> <new_adapter_version> [actor]');
}

async function main(){
  const c=await pool.connect();
  try{
    await c.query('begin');
    const s=await c.query(`
      select * from retail.retail_search_adapters where id=$1
    `,[sourceAdapterId]);
    if(!s.rowCount) throw new Error('source adapter missing');
    const a=s.rows[0];

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
        certification_status,created_by
      )
      values(
        $1,$2,$3,$4,$5,$6,$7,
        $8,$9,$10,$11,$12,$13,$14,
        $15::jsonb,$16,$17::jsonb,$18,
        $19::jsonb,$20,$21::jsonb,$22,
        'uncertified',$23
      )
      returning id,adapter_code,adapter_version
    `,[
      a.platform_id,a.adapter_type,a.adapter_code,newVersion,
      a.implementation_ref,a.implementation_sha256,a.git_commit_sha,
      a.supports_keyword_search,a.supports_product_url,a.supports_category_search,
      a.supports_store_id,a.supports_postal_code,a.supports_region,a.supports_result_limit,
      JSON.stringify(a.supported_collection_methods),a.supports_all_collection_methods,
      JSON.stringify(a.supported_source_types),a.supports_all_source_types,
      JSON.stringify(a.input_contract_json),a.input_contract_sha256,
      JSON.stringify(a.capability_json),a.capability_sha256,
      actor
    ]);

    await c.query('commit');
    console.log(JSON.stringify({
      event:'r1b_adapter_version_cloned_for_scraper_authority',
      sourceAdapterId,
      newAdapter:r.rows[0]
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
