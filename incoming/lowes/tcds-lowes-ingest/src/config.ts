import { z } from 'zod';

const env = z.object({
  DATABASE_URL: z.string().min(1),
  BRIGHT_DATA_API_TOKEN: z.string().min(1),
  LOWES_DATASET_ID: z.string().default('gd_lnvl79pfftqh18u2o'),
  BRIGHT_DATA_UNLOCKER_ZONE: z.string().default('tcds_web_unlocker'),
  BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE: z.string().default('tcds_premium_unlocker'),
  LOWES_UNLOCKER_MODE: z.enum(['disabled','fallback','always']).default('always'),
  LOWES_UNLOCKER_ZONE_POLICY: z.enum(['standard_only','premium_only','standard_then_premium']).default('standard_only'),
  LOWES_UNLOCKER_COUNTRY: z.string().length(2).default('us'),
  LOWES_SEED_URLS: z.string().default('https://www.lowes.com/pl/power-tools/4294607842?goToProdList=true,https://www.lowes.com/pl/outdoor-tools-equipment/lawn-mowers/push-lawn-mowers/4294612707'),
  LOWES_LOCATION: z.string().default(''),
  LOWES_LIMIT_PER_INPUT: z.coerce.number().int().min(1).max(1000).default(50),
  LOWES_DETAIL_LIMIT_PER_INPUT: z.coerce.number().int().min(1).max(10).default(1),
  HTTP_TIMEOUT_MS: z.coerce.number().int().min(1000).default(300000),
  HTTP_MAX_ATTEMPTS: z.coerce.number().int().min(1).max(10).default(6),
  SNAPSHOT_POLL_INTERVAL_MS: z.coerce.number().int().min(1000).default(15000),
  SNAPSHOT_MAX_WAIT_MS: z.coerce.number().int().min(60000).default(3600000),
  INGEST_CONCURRENCY: z.coerce.number().int().min(1).max(20).default(4),
  DLQ_DIRECTORY: z.string().default('./dlq'),
  LOG_LEVEL: z.enum(['debug','info','warn','error']).default('info')
}).parse(process.env);

export const config = {
  ...env,
  seedUrls: [...new Set(env.LOWES_SEED_URLS.split(',').map(x => x.trim()).filter(Boolean))]
};
