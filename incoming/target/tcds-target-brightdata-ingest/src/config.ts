import 'dotenv/config';
import { z } from 'zod';

const envSchema = z.object({
  DATABASE_URL: z.string().min(1),
  BRIGHT_DATA_API_TOKEN: z.string().min(10),
  BRIGHT_DATA_TARGET_DATASET_ID:
    z.string().default('gd_ltppk5mx2lp0v1k0vo'),
  BRIGHT_DATA_UNLOCKER_ZONE: z.string().default('tcds_web_unlocker'),
  BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE:
    z.string().default('tcds_premium_unlocker'),
  TARGET_UNLOCKER_MODE:
    z.enum(['disabled', 'fallback', 'always']).default('fallback'),
  TARGET_UNLOCKER_ZONE_POLICY:
    z.enum(['standard_only', 'premium_only', 'standard_then_premium'])
      .default('standard_then_premium'),
  TARGET_KEYWORDS:
    z.string().default('headphone,computers,laptops,smart-watches'),
  TARGET_ZIPCODES: z.string().default(''),
  TARGET_LIMIT_PER_INPUT:
    z.coerce.number().int().min(1).max(1000).default(1000),
  HTTP_TIMEOUT_MS: z.coerce.number().int().min(1000).default(120000),
  POLL_INTERVAL_MS: z.coerce.number().int().min(1000).default(15000),
  POLL_TIMEOUT_MS:
    z.coerce.number().int().min(60000).default(3600000),
  MAX_HTTP_ATTEMPTS:
    z.coerce.number().int().min(1).max(12).default(7),
  MAX_RECORD_ATTEMPTS:
    z.coerce.number().int().min(1).max(10).default(3),
  MAX_CONCURRENCY:
    z.coerce.number().int().min(1).max(32).default(4),
  LOG_LEVEL: z.string().default('info'),
  DLQ_DIR: z.string().default('./deadletters'),
  PARSER_VERSION: z.string().default('brightdata_target_v1'),
  SOURCE_DATASET: z.string().default('brightdata_target')
});

export function buildTargetDiscoveryInput(
  keywordValue: string,
  zipcodeValue: string
) {
  const keywords = [
    ...new Set(
      keywordValue.split(',').map(item => item.trim()).filter(Boolean)
    )
  ];

  if (keywords.length === 0) {
    throw new Error('TARGET_KEYWORDS must contain at least one keyword');
  }

  const zipcodes = zipcodeValue
    .split(',')
    .map(item => item.trim())
    .filter(Boolean);

  for (const zipcode of zipcodes) {
    if (!/^\d{5}(?:-\d{4})?$/.test(zipcode)) {
      throw new Error(
        `TARGET_ZIPCODES contains an invalid U.S. ZIP code: ${zipcode}`
      );
    }
  }

  if (zipcodes.length > 1 && zipcodes.length !== keywords.length) {
    throw new Error(
      'TARGET_ZIPCODES must contain zero, one, or one ZIP per keyword'
    );
  }

  const input = keywords.map((keywords, index) => ({
    keywords,
    zipcode:
      zipcodes.length === 1
        ? zipcodes[0]
        : zipcodes[index] ?? ''
  }));

  return { keywords, zipcodes, input };
}

const env = envSchema.parse(process.env);
const discovery = buildTargetDiscoveryInput(
  env.TARGET_KEYWORDS,
  env.TARGET_ZIPCODES
);

export const config = {
  ...env,
  ...discovery
};
