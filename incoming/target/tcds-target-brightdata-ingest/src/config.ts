import 'dotenv/config';
import { z } from 'zod';
const envSchema=z.object({
  DATABASE_URL:z.string().min(1), BRIGHT_DATA_API_TOKEN:z.string().min(10),
  BRIGHT_DATA_TARGET_DATASET_ID:z.string().default('gd_ltppk5mx2lp0v1k0vo'),
  BRIGHT_DATA_UNLOCKER_ZONE:z.string().default('tcds_web_unlocker'),
  BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE:z.string().default('tcds_premium_unlocker'),
  TARGET_UNLOCKER_MODE:z.enum(['disabled','fallback','always']).default('fallback'),
  TARGET_UNLOCKER_ZONE_POLICY:z.enum(['standard_only','premium_only','standard_then_premium']).default('standard_then_premium'),
  TARGET_KEYWORDS:z.string().default('headphone,computers,laptops,smart-watches'), TARGET_ZIPCODES:z.string().default(''),
  TARGET_LIMIT_PER_INPUT:z.coerce.number().int().min(1).max(1000).default(1000), HTTP_TIMEOUT_MS:z.coerce.number().int().min(1000).default(120000),
  POLL_INTERVAL_MS:z.coerce.number().int().min(1000).default(15000), POLL_TIMEOUT_MS:z.coerce.number().int().min(60000).default(3600000),
  MAX_HTTP_ATTEMPTS:z.coerce.number().int().min(1).max(12).default(7), MAX_RECORD_ATTEMPTS:z.coerce.number().int().min(1).max(10).default(3),
  MAX_CONCURRENCY:z.coerce.number().int().min(1).max(32).default(4), LOG_LEVEL:z.string().default('info'), DLQ_DIR:z.string().default('./deadletters'),
  PARSER_VERSION:z.string().default('brightdata_target_v1'), SOURCE_DATASET:z.string().default('brightdata_target')
});
const e=envSchema.parse(process.env);
export const config={...e, keywords:e.TARGET_KEYWORDS.split(',').map(x=>x.trim()).filter(Boolean), zipcodes:e.TARGET_ZIPCODES.split(',').map(x=>x.trim()), input: e.TARGET_KEYWORDS.split(',').map(x=>x.trim()).filter(Boolean).map((keywords,i)=>({keywords,zipcode:e.TARGET_ZIPCODES.split(',').map(x=>x.trim())[i]??''}))};
