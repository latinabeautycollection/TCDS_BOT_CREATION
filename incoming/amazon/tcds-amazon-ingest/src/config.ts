import { z } from 'zod';

const envSchema = z.object({
  DATABASE_URL: z.string().min(1),
  BRIGHT_DATA_API_TOKEN: z.string().min(1),
  AMAZON_DATASET_ID: z.string().default('gd_l7q7dkf244hwjntr0'),
  BRIGHT_DATA_UNLOCKER_ZONE: z.string().default('tcds_web_unlocker'),
  BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE:
    z.string().default('tcds_premium_unlocker'),
  AMAZON_UNLOCKER_MODE:
    z.enum(['disabled', 'fallback', 'always']).default('fallback'),
  AMAZON_UNLOCKER_ZONE_POLICY:
    z.enum(['standard_only', 'premium_only', 'standard_then_premium'])
      .default('standard_then_premium'),
  AMAZON_KEYWORDS: z.string().default('smart watch,laptops,iphone'),
  AMAZON_ZIPCODE: z.string().default(''),
  AMAZON_LIMIT_PER_INPUT:
    z.coerce.number().int().min(1).max(1000).default(1000),
  HTTP_TIMEOUT_MS: z.coerce.number().int().min(1000).default(45000),
  HTTP_MAX_ATTEMPTS: z.coerce.number().int().min(1).max(10).default(6),
  SNAPSHOT_POLL_INTERVAL_MS:
    z.coerce.number().int().min(1000).default(15000),
  SNAPSHOT_MAX_WAIT_MS:
    z.coerce.number().int().min(60000).default(3600000),
  INGEST_CONCURRENCY:
    z.coerce.number().int().min(1).max(20).default(4),
  DLQ_DIRECTORY: z.string().default('./dlq'),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info')
});

export function parseAmazonKeywords(value: string): string[] {
  const keywords = [
    ...new Set(value.split(',').map(item => item.trim()).filter(Boolean))
  ];

  if (keywords.length === 0) {
    throw new Error('AMAZON_KEYWORDS must contain at least one keyword');
  }

  return keywords;
}

export function parseAmazonZipcode(value: string): string {
  const zipcode = value.trim();

  if (zipcode && !/^\d{5}(?:-\d{4})?$/.test(zipcode)) {
    throw new Error('AMAZON_ZIPCODE must be a valid U.S. ZIP code');
  }

  return zipcode;
}

const env = envSchema.parse(process.env);

export const config = {
  ...env,
  AMAZON_ZIPCODE: parseAmazonZipcode(env.AMAZON_ZIPCODE),
  keywords: parseAmazonKeywords(env.AMAZON_KEYWORDS)
};
