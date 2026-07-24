import pg from 'pg';
import { config } from './config.js';
import { sha256, stableJson, money, availability } from './util.js';
import type { SEARSRecord } from './types.js';

const { Pool } = pg;
const pgJson = (value: unknown) => JSON.stringify(value);

export const pool = new Pool({
  connectionString: config.DATABASE_URL,
  max: 10,
  statement_timeout: 60_000,
  query_timeout: 65_000,
  application_name: 'tcds-sears-ingest'
});

export async function platformAndConfig() {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    const p = await c.query(`SELECT id FROM retail.retail_platforms WHERE platform_code='sears'`);
    if (!p.rowCount) throw new Error("Sears platform missing; run migration");
    const cfg = await c.query(
      `SELECT id FROM retail.platform_collection_configs WHERE platform_id=$1 AND is_active ORDER BY updated_at DESC LIMIT 1`,
      [p.rows[0].id]
    );
    await c.query('COMMIT');
    return { platformId: p.rows[0].id as string, configId: cfg.rows[0]?.id as string | undefined };
  } catch (e) {
    await c.query('ROLLBACK');
    throw e;
  } finally { c.release(); }
}

export async function createRun(platformId:string, configId:string|undefined, runKey:string, urls:string[]) {
  const r = await pool.query(
    `INSERT INTO retail.collection_runs(platform_id,config_id,run_key,status,started_at,requested_by,total_requested,run_metadata)
     VALUES($1,$2,$3,'running',now(),'sears_worker',$4,$5) RETURNING id`,
    [platformId, configId ?? null, runKey, urls.length, pgJson({ discovery_source: config.SEARS_SITEMAP_INDEX_URL, discovered_urls: urls })]
  );
  return r.rows[0].id as string;
}

export async function resumeRun(id:string,platformId:string) {
  const run=await pool.query(
    `UPDATE retail.collection_runs
     SET status='running',completed_at=NULL,failure_reason=NULL
     WHERE id=$1 AND platform_id=$2
     RETURNING id`,
    [id,platformId]
  );
  if (!run.rowCount) throw new Error(`Sears run ${id} was not found for this platform`);
  return getRunProgress(id);
}

export async function getRunProgress(id:string) {
  const result=await pool.query(
    `SELECT
       (SELECT count(*)::integer
        FROM retail.sears_product_parsed
        WHERE collection_run_id=$1) AS collected,
       (SELECT count(DISTINCT raw_payload #>> '{input,url}')::integer
        FROM retail.ingest_dead_letters
        WHERE collection_run_id=$1
          AND status IN ('pending','retrying','abandoned')) AS skipped,
       ARRAY(
         SELECT url FROM retail.sears_product_parsed WHERE collection_run_id=$1
         UNION
         SELECT raw_payload #>> '{input,url}'
         FROM retail.ingest_dead_letters
         WHERE collection_run_id=$1
           AND raw_payload #>> '{input,url}' IS NOT NULL
       ) AS attempted_urls`,
    [id]
  );
  return {
    collected:Number(result.rows[0]?.collected??0),
    skipped:Number(result.rows[0]?.skipped??0),
    attemptedUrls:new Set<string>((result.rows[0]?.attempted_urls??[]) as string[])
  };
}

export async function updateRunRequestTotal(id:string,total:number,metadata:unknown) {
  await pool.query(
    `UPDATE retail.collection_runs
     SET total_requested=$2,run_metadata=coalesce(run_metadata,'{}'::jsonb)||$3::jsonb
     WHERE id=$1`,
    [id,total,pgJson(metadata)]
  );
}

export async function finishRun(id:string,status:'completed'|'partial'|'failed',stats:{collected:number;failed:number;skipped:number},reason?:string) {
  await pool.query(
    `UPDATE retail.collection_runs SET status=$2,completed_at=now(),total_collected=$3,total_failed=$4,total_skipped=$5,failure_reason=$6 WHERE id=$1`,
    [id,status,stats.collected,stats.failed,stats.skipped,reason??null]
  );
}

export async function deadLetter(platformId:string,runId:string|null,payload:unknown,code:string,message:string,attempt=1) {
  const raw=stableJson(payload), hash=sha256(raw);
  await pool.query(
    `INSERT INTO retail.ingest_dead_letters(platform_id,collection_run_id,source_platform,payload_hash,raw_payload,error_code,error_message,attempt_count,next_retry_at)
     VALUES($1,$2,'sears',$3,$4,$5,$6,$7,now()+interval '15 minutes')
     ON CONFLICT(source_platform,payload_hash) DO UPDATE SET
       error_code=EXCLUDED.error_code,error_message=EXCLUDED.error_message,
       attempt_count=retail.ingest_dead_letters.attempt_count+1,last_failed_at=now(),
       next_retry_at=now()+least(interval '24 hours',interval '15 minutes'*power(2,least(retail.ingest_dead_letters.attempt_count,6)))`,
    [platformId,runId,hash,pgJson(payload),code,message.slice(0,8000),attempt]
  );
}

export async function saveEvidence(platformId:string,runId:string,url:string,zone:string,body:string,contentType:string,status:number,meta:unknown) {
  await pool.query(
    `INSERT INTO retail.sears_unlocker_evidence(collection_run_id,platform_id,target_url,unlocker_zone,content_type,response_status,content_hash,response_body,evidence_metadata)
     VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT(content_hash) DO NOTHING`,
    [runId,platformId,url,zone,contentType,status,sha256(body),body,pgJson(meta)]
  );
}

function isTargetScope(r:SEARSRecord): boolean {
  const text=[r.title,r.product_category,...r.category_tree.map(x=>x.name)].filter(Boolean).join(' ').toLowerCase();
  return /(tv|television|home theater|audio|soundbar|speaker|receiver|computer|laptop|notebook|desktop|monitor|gaming|tool|drill|saw|impact|grinder|power tool|battery|charger|appliance|range|refrigerator|washer|dryer|microwave)/i.test(text);
}

function inferredManufacturer(r:SEARSRecord): string|null {
  const title=(r.title??'').toLowerCase();
  const known=['samsung','lg','sony','dewalt','craftsman','milwaukee','makita','bosch','hisense','tcl','hp','dell','lenovo','asus','acer','apple'];
  return known.find(x=>title.includes(x))??null;
}

export async function ingestRecord(platformId:string,runId:string,r:SEARSRecord) {
  const c=await pool.connect();
  const raw=stableJson(r), payloadHash=sha256(raw), regular=money(r.price), sale=money(r.sale_price);
  const validPrices=[regular,sale].filter((x):x is number=>x!==null);
  const effective=validPrices.length?Math.min(...validPrices):null;
  const scopeMatch=isTargetScope(r);
  const inferredBrand=inferredManufacturer(r);
  const brandMismatch=!!inferredBrand && !!r.brand && r.brand.toLowerCase()!==inferredBrand && r.brand.toLowerCase()==='sears';
  const priceInversion=regular!==null&&sale!==null&&sale>regular;
  try {
    await c.query('BEGIN');
    const rawQ=await c.query(
      `INSERT INTO retail.raw_product_captures(platform_id,collection_run_id,platform_product_key,source_url,raw_title,raw_brand,raw_category,raw_payload,payload_hash,parser_version,capture_metadata,source_platform)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,'web_unlocker_sears_v2',$10,'sears')
       ON CONFLICT(platform_id,platform_product_key,payload_hash) DO UPDATE SET captured_at=now() RETURNING id`,
      [platformId,runId,r.item_id,r.url,r.title,r.brand??null,r.product_category??null,pgJson(r),payloadHash,pgJson({discovery_source:config.SEARS_SITEMAP_INDEX_URL,variant_id:r.variant_id})]
    );
    const rawId=rawQ.rows[0].id as string;

    const parsed=await c.query(
      `INSERT INTO retail.sears_product_parsed(raw_capture_id,collection_run_id,platform_id,item_id,variant_id,group_id,gtin,mpn,url,title,description,brand,product_category,category_tree,image_url,additional_image_urls,additional_video_urls,regular_price,sale_price,effective_price,availability,availability_date,listing_has_variations,variant_attributes,variants,store_name,seller_url,seller_privacy_policy,seller_tos,return_policy,return_window,review_count,star_rating,reviews,target_countries,store_country,category_urls,parsed_payload,payload_hash)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29,$30,$31,$32,$33,$34,$35,$36,$37,$38,$39)
       ON CONFLICT(raw_capture_id) DO UPDATE SET updated_at=now() RETURNING id`,
      [rawId,runId,platformId,r.item_id,r.variant_id,r.group_id,r.gtin,r.mpn,r.url,r.title,r.description,r.brand,r.product_category,pgJson(r.category_tree),r.image_url,pgJson(r.additional_image_urls),pgJson(r.additional_video_urls),regular,sale,effective,r.availability,r.availability_date,r.listing_has_variations,pgJson(r.variant_attributes),pgJson(r.variants),r.store_name,r.seller_url,r.seller_privacy_policy,r.seller_tos,r.return_policy,r.return_window,r.review_count,r.star_rating,pgJson(r.reviews),pgJson(r.target_countries),r.store_country,pgJson(r.category_urls),pgJson(r),payloadHash]
    );
    const parsedId=parsed.rows[0].id as string;

    const product=await c.query(
      `INSERT INTO retail.retail_products(platform_id,platform_product_key,source_url,title,brand,manufacturer,model_number,upc,ean,asin,sku,category_path,image_url,normalized_json)
       VALUES($1,$2,$3,$4,$5,$6,$7,NULL,NULL,NULL,$8,$9,$10,$11)
       ON CONFLICT(platform_id,platform_product_key) DO UPDATE SET
         source_url=EXCLUDED.source_url,title=EXCLUDED.title,brand=EXCLUDED.brand,model_number=EXCLUDED.model_number,
         sku=EXCLUDED.sku,category_path=EXCLUDED.category_path,image_url=EXCLUDED.image_url,last_seen_at=now(),is_active=true,
         normalized_json=EXCLUDED.normalized_json,updated_at=now() RETURNING id`,
      [platformId,r.item_id,r.url,r.title,r.brand,inferredBrand,r.mpn,r.variant_id,r.product_category,r.image_url,pgJson({gtin:r.gtin,group_id:r.group_id,availability_date:r.availability_date,source_brand:r.brand,inferred_manufacturer:inferredBrand})]
    );
    const productId=product.rows[0].id as string;
    const av=availability(r.availability);

    if (!scopeMatch) {
      await c.query(
        `INSERT INTO retail.data_quality_events(platform_id,retail_product_id,collection_run_id,event_code,severity,event_message,event_json)
         VALUES($1,$2,$3,'SEARS_COLLECTION_SCOPE_MISMATCH','high','Sears electronics, laptops, and portable power-tools seed returned a product outside the governed TCDS scope',$4)`,
        [platformId,productId,runId,pgJson({item_id:r.item_id,url:r.url,title:r.title,product_category:r.product_category,raw_capture_id:rawId})]
      );
    }
    if (brandMismatch) {
      await c.query(
        `INSERT INTO retail.data_quality_events(platform_id,retail_product_id,collection_run_id,event_code,severity,event_message,event_json)
         VALUES($1,$2,$3,'SEARS_BRAND_MANUFACTURER_MISMATCH','high','Sears source brand conflicts with manufacturer inferred from product title; raw brand preserved and inferred manufacturer stored separately',$4)`,
        [platformId,productId,runId,pgJson({item_id:r.item_id,url:r.url,source_brand:r.brand,inferred_manufacturer:inferredBrand,title:r.title,raw_capture_id:rawId})]
      );
    }
    if (av==='out_of_stock') {
      await c.query(
        `INSERT INTO retail.data_quality_events(platform_id,retail_product_id,collection_run_id,event_code,severity,event_message,event_json)
         VALUES($1,$2,$3,'SEARS_OUT_OF_STOCK','low','Sears product is currently out of stock; evidence retained and offer marked unavailable',$4)`,
        [platformId,productId,runId,pgJson({item_id:r.item_id,url:r.url,raw_availability:r.availability,raw_capture_id:rawId})]
      );
    }
    if (priceInversion) {
      await c.query(
        `INSERT INTO retail.data_quality_events(platform_id,retail_product_id,collection_run_id,event_code,severity,event_message,event_json)
         VALUES($1,$2,$3,'SEARS_PRICE_FIELD_INVERSION','high','Sears sale_price exceeded regular price; lowest valid observed price selected',$4)`,
        [platformId,productId,runId,pgJson({item_id:r.item_id,url:r.url,regular_price:regular,sale_price:sale,effective_price:effective,raw_capture_id:rawId})]
      );
    }
    if (regular !== null && sale !== null && Math.abs(regular - sale) < 0.005) {
      await c.query(
        `INSERT INTO retail.data_quality_events(platform_id,retail_product_id,collection_run_id,event_code,severity,event_message,event_json)
         VALUES($1,$2,$3,'SEARS_SEED_RESULT_NO_DISCOUNT','medium','Sears seed result has equal regular and sale prices; preserve evidence but do not assume discount qualification',$4)`,
        [platformId,productId,runId,pgJson({item_id:r.item_id,url:r.url,regular_price:regular,sale_price:sale,raw_capture_id:rawId})]
      );
    }

    await c.query(
      `INSERT INTO retail.product_inventory_history(retail_product_id,platform_id,availability,shipping_available,captured_at,raw_capture_id,inventory_metadata)
       VALUES($1,$2,$3,$4,now(),$5,$6)`,
      [productId,platformId,av,av==='in_stock',rawId,pgJson({raw_availability:r.availability,availability_date:r.availability_date})]
    );

    if (effective !== null) {
      await c.query(
        `INSERT INTO retail.product_price_history(retail_product_id,platform_id,price_signal_type,currency_code,regular_price,sale_price,effective_price,raw_capture_id,price_metadata)
         VALUES($1,$2,'regular_price','USD',$3,$4,$5,$6,$7)`,
        [productId,platformId,regular,sale,effective,rawId,pgJson({source:'sears',effective_price_rule:'lowest_valid_observed_price',collection_scope_match:scopeMatch,price_field_inversion:priceInversion})]
      );
      const offerHash=sha256(stableJson({platformId,productId,effective,av,url:r.url}));
      const offer=await c.query(
        `INSERT INTO retail.retail_offer_snapshots(retail_product_id,platform_id,effective_price,currency_code,availability,source_url,raw_capture_id,offer_hash,offer_metadata)
         VALUES($1,$2,$3,'USD',$4,$5,$6,$7,$8)
         ON CONFLICT(platform_id,offer_hash) DO UPDATE SET captured_at=now() RETURNING id`,
        [productId,platformId,effective,av,r.url,rawId,offerHash,pgJson({sears_parsed_id:parsedId,regular_price:regular,sale_price:sale,effective_price_rule:'lowest_valid_observed_price',collection_scope_match:scopeMatch,price_field_inversion:priceInversion})]
      );
      await c.query(
        `INSERT INTO retail.current_retail_offers(retail_product_id,platform_id,latest_offer_snapshot_id,effective_price,availability,first_seen_at,last_seen_at,source_url,offer_metadata)
         VALUES($1,$2,$3,$4,$5,now(),now(),$6,$7)
         ON CONFLICT(retail_product_id) DO UPDATE SET latest_offer_snapshot_id=EXCLUDED.latest_offer_snapshot_id,
           effective_price=EXCLUDED.effective_price,availability=EXCLUDED.availability,last_seen_at=now(),
           seen_count=retail.current_retail_offers.seen_count+1,source_url=EXCLUDED.source_url,
           offer_metadata=EXCLUDED.offer_metadata,updated_at=now()`,
        [productId,platformId,offer.rows[0].id,effective,av,r.url,pgJson({sears_parsed_id:parsedId,collection_scope_match:scopeMatch,price_field_inversion:priceInversion})]
      );
    } else {
      await c.query(
        `INSERT INTO retail.data_quality_events(platform_id,retail_product_id,collection_run_id,event_code,severity,event_message,event_json)
         VALUES($1,$2,$3,'SEARS_PRICE_MISSING','medium','Sears dataset returned no usable price; product preserved but offer promotion withheld',$4)`,
        [platformId,productId,runId,pgJson({item_id:r.item_id,url:r.url,price:r.price,sale_price:r.sale_price,raw_capture_id:rawId})]
      );
    }

    const imgs=[r.image_url,...r.additional_image_urls].filter((x):x is string=>!!x).slice(0,config.SEARS_MAX_IMAGES_PER_PRODUCT);
    for(const [i,u] of [...new Set(imgs)].entries())
      await c.query(`INSERT INTO retail.sears_product_images(sears_parsed_id,image_url,image_rank,is_main) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`,[parsedId,u,i+1,i===0]);
    for(const [i,x] of r.category_tree.entries())
      await c.query(`INSERT INTO retail.sears_product_categories(sears_parsed_id,category_rank,category_name,category_url) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`,[parsedId,i+1,x.name,x.url??null]);
    for (const [i, spec] of r.variant_attributes.entries()) {
      if (!spec || typeof spec !== 'object') continue;
      const row = spec as Record<string, unknown>;
      const name = typeof row.name === 'string' ? row.name.trim() : '';
      const value = typeof row.value === 'string' ? row.value.trim() : row.value == null ? null : String(row.value);
      if (!name) continue;
      await c.query(`INSERT INTO retail.sears_product_specifications(sears_parsed_id,specification_rank,specification_name,specification_value) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`,[parsedId,i+1,name,value]);
    }

    await c.query('COMMIT');
  } catch(e) {
    await c.query('ROLLBACK');
    throw e;
  } finally { c.release(); }
}
