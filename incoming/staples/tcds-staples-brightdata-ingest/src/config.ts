import 'dotenv/config';
import { z } from 'zod';
const envSchema=z.object({
  DATABASE_URL:z.string().min(1), BRIGHT_DATA_API_TOKEN:z.string().min(10),
  BRIGHT_DATA_STAPLES_DATASET_ID:z.string().default('gd_mkpali8c17mjkucviv'),
  BRIGHT_DATA_UNLOCKER_ZONE:z.string().default('tcds_web_unlocker'),
  BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE:z.string().default('tcds_premium_unlocker'),
  STAPLES_UNLOCKER_MODE:z.enum(['disabled','fallback','always']).default('fallback'),
  STAPLES_UNLOCKER_ZONE_POLICY:z.enum(['standard_only','premium_only','standard_then_premium']).default('standard_then_premium'),
  STAPLES_SEED_URLS:z.string().default('https://www.staples.com/deals/computer-deals/BI3001698'),
  STAPLES_LIMIT_PER_INPUT:z.coerce.number().int().min(1).max(1000).default(1000), HTTP_TIMEOUT_MS:z.coerce.number().int().min(1000).default(120000),
  POLL_INTERVAL_MS:z.coerce.number().int().min(1000).default(15000), POLL_TIMEOUT_MS:z.coerce.number().int().min(60000).default(3600000),
  MAX_HTTP_ATTEMPTS:z.coerce.number().int().min(1).max(12).default(7), MAX_RECORD_ATTEMPTS:z.coerce.number().int().min(1).max(10).default(3),
  MAX_CONCURRENCY:z.coerce.number().int().min(1).max(32).default(4), LOG_LEVEL:z.string().default('info'), DLQ_DIR:z.string().default('./deadletters'),
  PARSER_VERSION:z.string().default('brightdata_staples_v1'), SOURCE_DATASET:z.string().default('brightdata_staples')
});
const e=envSchema.parse(process.env);
const seedUrls=e.STAPLES_SEED_URLS.split(',').map(x=>x.trim()).filter(Boolean);
export const config={...e,seedUrls,input:seedUrls.map(url=>({url}))};
