import { z } from 'zod';

const env = z.object({
  DATABASE_URL: z.string().min(1),
  BRIGHT_DATA_API_TOKEN: z.string().min(1),
  OFFICE_DEPOT_DATASET_ID: z.string().default('gd_mktjw1cs1bedg8o196'),
  BRIGHT_DATA_UNLOCKER_ZONE: z.string().default('tcds_web_unlocker'),
  BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE: z.string().default('tcds_premium_unlocker'),
  OFFICE_DEPOT_UNLOCKER_MODE: z.enum(['disabled','fallback','always']).default('fallback'),
  OFFICE_DEPOT_UNLOCKER_ZONE_POLICY: z.enum(['standard_only','premium_only','standard_then_premium']).default('standard_only'),
  OFFICE_DEPOT_SEED_URLS: z.string().default('https://www.officedepot.com/l/deal-center/pc-deals,https://www.officedepot.com/b/electronics/Featured_Items--On_Sale/N-9021,https://www.officedepot.com/l/deal-center/printer-deals'),
  OFFICE_DEPOT_LIMIT_PER_INPUT: z.coerce.number().int().min(1).max(1000).default(50),
  HTTP_TIMEOUT_MS: z.coerce.number().int().min(1000).default(120000),
  HTTP_MAX_ATTEMPTS: z.coerce.number().int().min(1).max(10).default(6),
  SNAPSHOT_POLL_INTERVAL_MS: z.coerce.number().int().min(1000).default(15000),
  SNAPSHOT_MAX_WAIT_MS: z.coerce.number().int().min(60000).default(3600000),
  INGEST_CONCURRENCY: z.coerce.number().int().min(1).max(20).default(4),
  DLQ_DIRECTORY: z.string().default('./dlq'),
  LOG_LEVEL: z.enum(['debug','info','warn','error']).default('info')
}).parse(process.env);

export const config = {
  ...env,
  seedUrls: [...new Set(env.OFFICE_DEPOT_SEED_URLS.split(',').map(x => x.trim()).filter(Boolean))]
};
