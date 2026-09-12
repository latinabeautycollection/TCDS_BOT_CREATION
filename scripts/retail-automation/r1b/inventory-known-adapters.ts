import { Pool } from 'pg';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const REPO_ROOT = process.env.REPO_ROOT ?? process.cwd();

const KNOWN = [
  {
    platformCode: 'best_buy',
    adapterType: 'search',
    adapterCode: 'bestbuy_brightdata_search',
    version: '2',
    implementationRef: 'scripts/brightdata-bestbuy-webunlocker-search-ingest.ts',
    status: 'partially_dynamic',
    caps: {
      keywordSearch: true,
      productUrl: true,
      categorySearch: true,
      storeId: false,
      postalCode: false,
      region: false,
      resultLimit: true,
      collectionMethods: [
        'brightdata_dataset',
        'brightdata_unlocker'
      ],
      sourceTypes: ['sale']
    },
    inputContract: {
      keyword_env: 'BESTBUY_KEYWORDS',
      keyword_format: 'json_array_or_comma_separated',
      manual_test_url_env: 'BESTBUY_TEST_URL',
      discovery_limit_env: 'BESTBUY_LIMIT_PER_INPUT',
      result_limit_env: 'BESTBUY_MAX_ROWS',
      dataset_id_env: 'BESTBUY_DATASET_ID',
      web_unlocker_zone_env:
        'BRIGHTDATA_WEB_UNLOCKER_ZONE',
      store_id: null,
      postal_code: null
    }
  },
  {
    platformCode: 'walmart',
    adapterType: 'search',
    adapterCode: 'walmart_brightdata_test',
    version: '1',
    implementationRef: 'scripts/test-walmart-brightdata-ingest.ts',
    status: 'test_only',
    caps: {
      keywordSearch: false, productUrl: true, categorySearch: false,
      storeId: false, postalCode: false, region: false, resultLimit: false,
      collectionMethods: ['brightdata_dataset'],
      sourceTypes: []
    },
    inputContract: { product_url_test_harness: true }
  }
] as const;

const sha = (b: Buffer | string) =>
  createHash('sha256').update(b).digest('hex');

async function main() {
  const c = await pool.connect();
  try {
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','service_account',true)`);
    await c.query(`select set_config('app.actor_id','r1b-inventory',true)`);
    await c.query(`select set_config('app.actor_name','R1B Adapter Inventory',true)`);

    const out = [];
    for (const k of KNOWN) {
      const p = await c.query(
        `select id from retail.retail_platforms where platform_code=$1`,
        [k.platformCode]
      );
      if (!p.rowCount) {
        out.push({platform:k.platformCode,skipped:'PLATFORM_NOT_REGISTERED'});
        continue;
      }

      const implPath = path.resolve(REPO_ROOT,k.implementationRef);
      let implementationSha: string;
      try {
        implementationSha = sha(await readFile(implPath));
      } catch {
        out.push({platform:k.platformCode,skipped:'IMPLEMENTATION_FILE_MISSING',path:implPath});
        continue;
      }

      const existing = await c.query(
        `select *
           from retail.retail_search_adapters
          where platform_id=$1 and adapter_code=$2 and adapter_version=$3`,
        [p.rows[0].id,k.adapterCode,k.version]
      );

      if (existing.rowCount &&
          existing.rows[0].certification_status === 'certified_dynamic_search') {
        const e = existing.rows[0];
        const changed =
          e.implementation_sha256 !== implementationSha ||
          JSON.stringify(e.input_contract_json) !== JSON.stringify(k.inputContract);

        out.push({
          adapter:e.adapter_code,
          version:e.adapter_version,
          skipped: changed ? 'CERTIFIED_VERSION_CHANGED_CREATE_NEW_VERSION'
                           : 'CERTIFIED_VERSION_IMMUTABLE_NO_CHANGE'
        });
        continue;
      }

      const caps = k.caps;
      const r = await c.query(
        `insert into retail.retail_search_adapters(
           platform_id,adapter_type,adapter_code,adapter_version,
           implementation_ref,implementation_sha256,
           supports_keyword_search,supports_product_url,supports_category_search,
           supports_store_id,supports_postal_code,supports_region,supports_result_limit,
           supported_collection_methods,supports_all_collection_methods,supported_source_types,supports_all_source_types,
           input_contract_json,input_contract_sha256,
           capability_json,capability_sha256,
           certification_status,created_by
         )
         values(
           $1,$2,$3,$4,$5,$6,
           $7,$8,$9,$10,$11,$12,$13,
           $14::jsonb,false,$15::jsonb,false,$16::jsonb,repeat('0',64),
           '{}'::jsonb,repeat('0',64),$17,$18
         )
         on conflict(platform_id,adapter_code,adapter_version)
         do update set
           implementation_ref=excluded.implementation_ref,
           implementation_sha256=excluded.implementation_sha256,
           supports_keyword_search=excluded.supports_keyword_search,
           supports_product_url=excluded.supports_product_url,
           supports_category_search=excluded.supports_category_search,
           supports_store_id=excluded.supports_store_id,
           supports_postal_code=excluded.supports_postal_code,
           supports_region=excluded.supports_region,
           supports_result_limit=excluded.supports_result_limit,
           supported_collection_methods=excluded.supported_collection_methods,
           supported_source_types=excluded.supported_source_types,
           input_contract_json=excluded.input_contract_json,
           certification_status=case
             when retail.retail_search_adapters.certification_status in ('suspended','retired')
               then retail.retail_search_adapters.certification_status
             else excluded.certification_status
           end
         returning id,adapter_code,adapter_version,certification_status,
                   implementation_sha256,input_contract_sha256,capability_sha256`,
        [
          p.rows[0].id,k.adapterType,k.adapterCode,k.version,
          k.implementationRef,implementationSha,
          caps.keywordSearch,caps.productUrl,caps.categorySearch,
          caps.storeId,caps.postalCode,caps.region,caps.resultLimit,
          JSON.stringify(caps.collectionMethods),
          JSON.stringify(caps.sourceTypes),
          JSON.stringify(k.inputContract),
          k.status,'R1B Adapter Inventory'
        ]
      );
      out.push(r.rows[0]);
    }

    await c.query('commit');
    console.log(JSON.stringify({event:'r1b_adapter_inventory_complete',results:out},null,2));
  } catch(e) {
    await c.query('rollback');
    throw e;
  } finally {
    c.release();
    await pool.end();
  }
}

main().catch(e=>{ console.error(e); process.exitCode=1; });
