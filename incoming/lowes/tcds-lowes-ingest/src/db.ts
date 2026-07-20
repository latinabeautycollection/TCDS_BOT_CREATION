import pg from 'pg';
import { config } from './config.js';
import { sha256, stableJson, money, normalizeLowesPrices, availability } from './util.js';
import type { LowesRecord } from './types.js';

const { Pool } = pg;
export const pool = new Pool({
  connectionString: config.DATABASE_URL,
  max: 10,
  statement_timeout: 60_000,
  query_timeout: 65_000,
  application_name: 'tcds-lowes-ingest'
});

export async function platformAndConfig() {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    const p = await c.query(`SELECT id FROM retail.retail_platforms WHERE platform_code='lowes'`);
    if (!p.rowCount) throw new Error("Lowe's platform missing; run migration");
    const cfg = await c.query(`SELECT id FROM retail.platform_collection_configs WHERE platform_id=$1 AND is_active ORDER BY updated_at DESC LIMIT 1`,[p.rows[0].id]);
    await c.query('COMMIT');
    return { platformId: p.rows[0].id as string, configId: cfg.rows[0]?.id as string | undefined };
  } catch (e) { await c.query('ROLLBACK'); throw e; } finally { c.release(); }
}

export async function createRun(platformId:string, configId:string|undefined, runKey:string, urls:string[]) {
  const r=await pool.query(`INSERT INTO retail.collection_runs(platform_id,config_id,run_key,status,started_at,requested_by,total_requested,run_metadata)
    VALUES($1,$2,$3,'running',now(),'lowes_worker',$4,$5) RETURNING id`,
    [platformId,configId??null,runKey,urls.length,{dataset_id:config.LOWES_DATASET_ID,seed_urls:urls,location:config.LOWES_LOCATION}]);
  return r.rows[0].id as string;
}
export async function finishRun(id:string,status:'completed'|'partial'|'failed',stats:{collected:number;failed:number;skipped:number},reason?:string){
  await pool.query(`UPDATE retail.collection_runs SET status=$2::retail.collection_status,completed_at=now(),total_collected=$3,total_failed=$4,total_skipped=$5,failure_reason=$6 WHERE id=$1`,[id,status,stats.collected,stats.failed,stats.skipped,reason??null]);
}
export async function deadLetter(platformId:string,runId:string|null,payload:unknown,code:string,message:string,retryable=true,attempt=1){
  const raw=stableJson(payload),hash=sha256(raw);
  await pool.query(`INSERT INTO retail.ingest_dead_letters(platform_id,collection_run_id,source_platform,payload_hash,raw_payload,error_code,error_message,attempt_count,status,next_retry_at,resolution_notes)
    VALUES($1,$2,'lowes',$3,$4,$5,$6,$7,$8,CASE WHEN $8='abandoned' THEN NULL ELSE now()+interval '15 minutes' END,$9)
    ON CONFLICT(source_platform,payload_hash) DO UPDATE SET collection_run_id=EXCLUDED.collection_run_id,error_code=EXCLUDED.error_code,error_message=EXCLUDED.error_message,
    attempt_count=retail.ingest_dead_letters.attempt_count+1,last_failed_at=now(),
    status=EXCLUDED.status,next_retry_at=EXCLUDED.next_retry_at,resolution_notes=EXCLUDED.resolution_notes`,
    [platformId,runId,hash,payload,code,message.slice(0,8000),attempt,retryable?'pending':'abandoned',retryable?null:'Non-retryable provider error']);
}
export async function saveEvidence(platformId:string,runId:string,url:string,zone:string,body:string,contentType:string,status:number,meta:unknown){
  await pool.query(`INSERT INTO retail.lowes_unlocker_evidence(collection_run_id,platform_id,target_url,unlocker_zone,content_type,response_status,content_hash,response_body,evidence_metadata)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT(content_hash) DO NOTHING`,[runId,platformId,url,zone,contentType,status,sha256(body),body,meta]);
}

export async function ingestRecord(platformId:string,runId:string,r:LowesRecord){
  const c=await pool.connect();
  const raw=stableJson(r),payloadHash=sha256(raw);
  const normalized=normalizeLowesPrices(r.initial_price,r.final_price,r.price,r.sale_price);
  const effective=normalized.effective;
  const initial=money(r.initial_price), final=money(r.final_price), displayed=money(r.price), sale=money(r.sale_price);
  const discountValue=money(r.discount);
  const computedDiscount=initial!==null&&effective!==null&&initial>0?Math.max(0,((initial-effective)/initial)*100):null;
  const suspiciousDiscount=discountValue!==null&&computedDiscount!==null&&Math.abs(discountValue-computedDiscount)>5;
  const av=availability(r.availability_status ?? (r.in_stock ? 'in_stock' : r.availability.join(' ')));
  const itemId=r.marketplace_pn;
  const jsonValue=(value:unknown)=>value==null?null:stableJson(value);
  try{
    await c.query('BEGIN');
    const rawQ=await c.query(`INSERT INTO retail.raw_product_captures(platform_id,collection_run_id,platform_product_key,source_url,raw_title,raw_brand,raw_category,raw_payload,payload_hash,parser_version,capture_metadata,source_platform)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,'brightdata_lowes_v1',$10,'lowes')
      ON CONFLICT(platform_id,platform_product_key,payload_hash) DO UPDATE SET captured_at=now() RETURNING id`,
      [platformId,runId,itemId,r.url,r.product_name,r.brand??null,r.product_category??r.root_category??null,stableJson(r),payloadHash,stableJson({dataset_id:config.LOWES_DATASET_ID,location:config.LOWES_LOCATION,sku:r.sku})]);
    const rawId=rawQ.rows[0].id as string;
    const parsed=await c.query(`INSERT INTO retail.lowes_product_parsed(raw_capture_id,collection_run_id,platform_id,marketplace_pn,sku,other_pn,model_number,gtin_ean_pn,upc,url,product_name,description,brand,product_category,root_category,category_tree,nai_category_tree,main_image,image_urls,initial_price,final_price,displayed_price,sale_price,effective_price,discount_value,computed_discount_percent,currency,in_stock,availability,availability_status,availability_date,available_to_delivery,delivery_offers,delivery,seller_name,seller_id,seller_url,date_first_available,badges,rating,reviews_count,reviews,top_reviews,dimensions,weight,specifications,listing_has_variations,variant_attributes,variants,store_name,location,in_store_location,seller_privacy_policy,seller_tos,return_policy,return_window,target_countries,store_country,category_urls,parsed_payload,payload_hash)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29,$30,$31,$32,$33,$34,$35,$36,$37,$38,$39,$40,$41,$42,$43,$44,$45,$46,$47,$48,$49,$50,$51,$52,$53,$54,$55,$56,$57,$58,$59,$60,$61)
      ON CONFLICT(raw_capture_id) DO UPDATE SET updated_at=now() RETURNING id`,
      [rawId,runId,platformId,itemId,r.sku,r.other_pn,r.model_number,r.gtin_ean_pn,r.upc,r.url,r.product_name,r.description,r.brand,r.product_category,r.root_category,stableJson(r.category_tree),stableJson(r.nai_category_tree),r.main_image,stableJson([...new Set([...r.image_urls,...r.additional_image_urls])]),initial,final,displayed,sale,effective,discountValue,computedDiscount,r.currency??'USD',r.in_stock,stableJson(r.availability),r.availability_status,r.availability_date,r.available_to_delivery,jsonValue(r.delivery_offers),stableJson(r.delivery),r.seller_name,r.seller_id,r.seller_url,r.date_first_available,stableJson(r.badges),r.rating,r.reviews_count,stableJson(r.reviews),stableJson(r.top_reviews),jsonValue(r.dimensions),r.weight,stableJson(r.Specifications),r.listing_has_variations,stableJson(r.variant_attributes),stableJson(r.variants),r.store_name,r.location,jsonValue(r.in_store_location),r.seller_privacy_policy,r.seller_tos,r.return_policy,r.return_window,stableJson(r.target_countries),r.store_country,stableJson(r.category_urls),stableJson(r),payloadHash]);
    const parsedId=parsed.rows[0].id as string;
    const product=await c.query(`INSERT INTO retail.retail_products(platform_id,platform_product_key,source_url,title,brand,manufacturer,model_number,upc,ean,asin,sku,category_path,image_url,normalized_json)
      VALUES($1,$2,$3,$4,$5,NULL,$6,$7,$8,NULL,$9,$10,$11,$12)
      ON CONFLICT(platform_id,platform_product_key) DO UPDATE SET source_url=EXCLUDED.source_url,title=EXCLUDED.title,brand=EXCLUDED.brand,
      model_number=EXCLUDED.model_number,upc=EXCLUDED.upc,ean=EXCLUDED.ean,sku=EXCLUDED.sku,category_path=EXCLUDED.category_path,image_url=EXCLUDED.image_url,
      last_seen_at=now(),is_active=true,normalized_json=EXCLUDED.normalized_json,updated_at=now() RETURNING id`,
      [platformId,itemId,r.url,r.product_name,r.brand,r.model_number,r.upc??r.gtin_ean_pn,r.gtin_ean_pn,r.sku,r.product_category,r.main_image,stableJson({other_pn:r.other_pn,seller_id:r.seller_id,location:r.location,store_name:r.store_name})]);
    const productId=product.rows[0].id as string;
    await c.query(`INSERT INTO retail.product_inventory_history(retail_product_id,platform_id,availability,quantity_available,store_pickup_available,shipping_available,delivery_available,captured_at,raw_capture_id,inventory_metadata)
      VALUES($1,$2,$3,$4,$5,$6,$7,now(),$8,$9)`,[productId,platformId,av,r.available_to_delivery??null,!!r.in_store_location,(r.in_stock??false),r.available_to_delivery!==null&&r.available_to_delivery!==undefined,rawId,stableJson({raw_availability:r.availability,availability_status:r.availability_status,location:r.location,in_store_location:r.in_store_location})]);
    if(effective!==null){
      await c.query(`INSERT INTO retail.product_price_history(retail_product_id,platform_id,price_signal_type,currency_code,regular_price,sale_price,effective_price,raw_capture_id,price_metadata)
        VALUES($1,$2,'regular_price',$3,$4,$5,$6,$7,$8)`,[productId,platformId,(r.currency??'USD').slice(0,3),normalized.regular,normalized.sale,effective,rawId,stableJson({displayed_price:displayed,final_price:final,source_discount:discountValue,computed_discount_percent:computedDiscount,suspicious_discount:suspiciousDiscount,effective_price_rule:'lowest_valid_observed_price'})]);
      const offerHash=sha256(stableJson({platformId,productId,effective,av,url:r.url,location:r.location}));
      const offer=await c.query(`INSERT INTO retail.retail_offer_snapshots(retail_product_id,platform_id,effective_price,currency_code,availability,quantity_available,source_url,raw_capture_id,offer_hash,offer_metadata)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) ON CONFLICT(platform_id,offer_hash) DO UPDATE SET captured_at=now() RETURNING id`,[productId,platformId,effective,(r.currency??'USD').slice(0,3),av,r.available_to_delivery??null,r.url,rawId,offerHash,stableJson({lowes_parsed_id:parsedId,initial_price:initial,final_price:final,displayed_price:displayed,sale_price:sale,discount_value:discountValue,computed_discount_percent:computedDiscount,location:r.location,seller_name:r.seller_name})]);
      await c.query(`INSERT INTO retail.current_retail_offers(retail_product_id,platform_id,latest_offer_snapshot_id,effective_price,availability,quantity_available,first_seen_at,last_seen_at,currency_code,source_url,offer_metadata)
        VALUES($1,$2,$3,$4,$5,$6,now(),now(),$7,$8,$9) ON CONFLICT(retail_product_id) DO UPDATE SET latest_offer_snapshot_id=EXCLUDED.latest_offer_snapshot_id,effective_price=EXCLUDED.effective_price,
        availability=EXCLUDED.availability,quantity_available=EXCLUDED.quantity_available,last_seen_at=now(),seen_count=retail.current_retail_offers.seen_count+1,currency_code=EXCLUDED.currency_code,source_url=EXCLUDED.source_url,offer_metadata=EXCLUDED.offer_metadata,updated_at=now()`,
        [productId,platformId,offer.rows[0].id,effective,av,r.available_to_delivery??null,(r.currency??'USD').slice(0,3),r.url,stableJson({lowes_parsed_id:parsedId,location:r.location,seller_name:r.seller_name,computed_discount_percent:computedDiscount})]);
    }else await c.query(`INSERT INTO retail.data_quality_events(platform_id,retail_product_id,collection_run_id,event_code,severity,event_message,event_json)
      VALUES($1,$2,$3,'LOWES_PRICE_MISSING','medium','Lowe''s dataset returned no usable price; product preserved but offer promotion withheld',$4)`,[platformId,productId,runId,stableJson({marketplace_pn:itemId,url:r.url,raw_capture_id:rawId})]);
    if(suspiciousDiscount) await c.query(`INSERT INTO retail.data_quality_events(platform_id,retail_product_id,collection_run_id,event_code,severity,event_message,event_json)
      VALUES($1,$2,$3,'LOWES_DISCOUNT_MISMATCH','high','Lowe''s source discount materially disagrees with the discount computed from observed prices',$4)`,[platformId,productId,runId,stableJson({marketplace_pn:itemId,source_discount:discountValue,computed_discount_percent:computedDiscount,initial_price:initial,effective_price:effective})]);
    const imgs=[r.main_image,...r.image_urls,...r.additional_image_urls].filter((x):x is string=>!!x);
    for(const [i,u] of [...new Set(imgs)].entries()) await c.query(`INSERT INTO retail.lowes_product_images(lowes_parsed_id,image_url,image_rank,is_main) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`,[parsedId,u,i+1,i===0]);
    const cats=r.nai_category_tree.length?r.nai_category_tree:r.category_tree.map((name,i)=>({name,url:r.category_urls[i]??null}));
    for(const [i,x] of cats.entries()) await c.query(`INSERT INTO retail.lowes_product_categories(lowes_parsed_id,category_rank,category_name,category_url) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`,[parsedId,i+1,x.name,x.url??null]);
    await c.query('COMMIT');
  }catch(e){await c.query('ROLLBACK');throw e;}finally{c.release();}
}
