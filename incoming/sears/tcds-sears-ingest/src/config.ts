import { z } from 'zod';
const env=z.object({
 DATABASE_URL:z.string().min(1),BRIGHT_DATA_API_TOKEN:z.string().min(1),
 SEARS_DATASET_ID:z.string().default('gd_mm9b61afxxhdl6r18'),
 BRIGHT_DATA_UNLOCKER_ZONE:z.string().default('tcds_web_unlocker'),
 BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE:z.string().default('tcds_premium_unlocker'),
 SEARS_UNLOCKER_MODE:z.enum(['disabled','fallback','always']).default('always'),
 SEARS_UNLOCKER_ZONE_POLICY:z.enum(['standard_only','premium_only','standard_then_premium']).default('standard_only'),
 SEARS_SITEMAP_INDEX_URL:z.string().url().default('https://www.sears.com/Sitemap_Index_Product_1.xml'),
 SEARS_SITEMAP_CATEGORIES:z.string().default('Appliances,Electronics,Tools'),
 SEARS_DISCOVERY_LIMIT:z.coerce.number().int().min(1).max(1000).default(500),
 SEARS_QA_TARGET:z.coerce.number().int().min(1).max(1000).default(50),
 SEARS_RUN_ID:z.string().uuid().optional(),
 SEARS_LIMIT_PER_INPUT:z.coerce.number().int().min(1).max(1000).default(1),
 HTTP_TIMEOUT_MS:z.coerce.number().int().min(1000).default(90000),HTTP_MAX_ATTEMPTS:z.coerce.number().int().min(1).max(10).default(2),
 SNAPSHOT_POLL_INTERVAL_MS:z.coerce.number().int().min(1000).default(15000),SNAPSHOT_MAX_WAIT_MS:z.coerce.number().int().min(60000).default(3600000),
 INGEST_CONCURRENCY:z.coerce.number().int().min(1).max(20).default(2),DLQ_DIRECTORY:z.string().default('./dlq'),LOG_LEVEL:z.enum(['debug','info','warn','error']).default('info'),
 SEARS_MAX_IMAGES_PER_PRODUCT:z.coerce.number().int().min(1).max(100).default(30)
}).parse(process.env);
export const config={
 ...env,
 sitemapCategories:[...new Set(env.SEARS_SITEMAP_CATEGORIES.split(',').map(x=>x.trim()).filter(Boolean))]
};
