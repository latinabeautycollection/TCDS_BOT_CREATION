import { z } from 'zod';

const env = z.object({
  DATABASE_URL: z.string().min(1),
  BRIGHT_DATA_API_TOKEN: z.string().min(1),
  COSTCO_DATASET_ID: z.string().default('gd_mkcbmac44j178pook'),
  BRIGHT_DATA_UNLOCKER_ZONE: z.string().default('tcds_web_unlocker'),
  BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE: z.string().default('tcds_premium_unlocker'),
  COSTCO_UNLOCKER_ZONE_POLICY: z.enum(['standard_only','premium_only','standard_then_premium']).default('standard_only'),
  COSTCO_SEED_URLS: z.string().default('https://www.costco.com/laptops.html,https://www.costco.com/tablet-computers-accessories.html,https://www.costco.com/aerial-cameras.html'),
  COSTCO_LIMIT_PER_INPUT: z.coerce.number().int().min(1).max(1000).default(50),
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
  seedUrls: [...new Set(env.COSTCO_SEED_URLS.split(',').map(x => x.trim()).filter(Boolean))]
};
