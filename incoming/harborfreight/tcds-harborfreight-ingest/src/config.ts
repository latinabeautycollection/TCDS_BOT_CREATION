import { z } from 'zod';
const env=z.object({
 DATABASE_URL:z.string().min(1),BRIGHT_DATA_API_TOKEN:z.string().min(1),
 HARBORFREIGHT_DATASET_ID:z.string().default('gd_mky1qkjbnsea4buxc'),
 BRIGHT_DATA_UNLOCKER_ZONE:z.string().default('tcds_web_unlocker'),
 BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE:z.string().default('tcds_premium_unlocker'),
 HARBORFREIGHT_UNLOCKER_MODE:z.enum(['disabled','fallback','always']).default('fallback'),
 HARBORFREIGHT_UNLOCKER_ZONE_POLICY:z.enum(['standard_only','premium_only','standard_then_premium']).default('standard_only'),
 HARBORFREIGHT_SEED_URLS:z.string().default('https://www.harborfreight.com/power-tools/drills-drivers.html,https://www.harborfreight.com/automotive/diagnostic-testing-scanning.html,https://www.harborfreight.com/automotive/battery-tools-accessories.html'),
 HARBORFREIGHT_LIMIT_PER_INPUT:z.coerce.number().int().min(1).max(1000).default(50),
 HTTP_TIMEOUT_MS:z.coerce.number().int().min(1000).default(120000),HTTP_MAX_ATTEMPTS:z.coerce.number().int().min(1).max(10).default(6),
 SNAPSHOT_POLL_INTERVAL_MS:z.coerce.number().int().min(1000).default(15000),SNAPSHOT_MAX_WAIT_MS:z.coerce.number().int().min(60000).default(3600000),
 INGEST_CONCURRENCY:z.coerce.number().int().min(1).max(20).default(4),DLQ_DIRECTORY:z.string().default('./dlq'),LOG_LEVEL:z.enum(['debug','info','warn','error']).default('info'),
 HARBORFREIGHT_MAX_IMAGES_PER_PRODUCT:z.coerce.number().int().min(1).max(100).default(30)
}).parse(process.env);
export const config={...env,seedUrls:[...new Set(env.HARBORFREIGHT_SEED_URLS.split(',').map(x=>x.trim()).filter(Boolean))]};
