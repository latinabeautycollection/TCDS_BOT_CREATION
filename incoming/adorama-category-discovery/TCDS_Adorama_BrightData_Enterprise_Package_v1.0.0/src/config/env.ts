import { z } from "zod";

const schema = z.object({
  NODE_ENV: z.enum(["development","test","production"]).default("production"),
  DATABASE_URL: z.string().min(1),
  BRIGHTDATA_API_TOKEN: z.string().min(1),
  BRIGHTDATA_DATASET_ID: z.string().default("gd_mlj9zzkr17l7vh9pno"),
  BRIGHTDATA_BASE_URL: z.string().url().default("https://api.brightdata.com"),
  BRIGHTDATA_WEB_UNLOCKER_ZONE: z.string().default("tcds_web_unlocker"),
  ADORAMA_LIMIT_PER_INPUT: z.coerce.number().int().positive().max(10000).default(50),
  ADORAMA_INPUT_URLS: z.string().min(1),
  HTTP_TIMEOUT_MS: z.coerce.number().int().positive().default(30000),
  TRIGGER_MAX_ATTEMPTS: z.coerce.number().int().positive().default(7),
  POLL_MAX_ATTEMPTS: z.coerce.number().int().positive().default(180),
  POLL_INTERVAL_MS: z.coerce.number().int().positive().default(20000),
  DOWNLOAD_MAX_ATTEMPTS: z.coerce.number().int().positive().default(7),
  RETRY_BASE_DELAY_MS: z.coerce.number().int().positive().default(1000),
  RETRY_MAX_DELAY_MS: z.coerce.number().int().positive().default(60000),
  JOB_LEASE_SECONDS: z.coerce.number().int().positive().default(300),
  WORKER_POLL_MS: z.coerce.number().int().positive().default(5000),
  BATCH_SIZE: z.coerce.number().int().positive().max(5000).default(500),
  LOG_LEVEL: z.string().default("info"),
  METRICS_PORT: z.coerce.number().int().positive().default(9464)
});
const parsed=schema.parse(process.env);
export const env={...parsed, inputUrls: parsed.ADORAMA_INPUT_URLS.split(',').map(x=>x.trim()).filter(Boolean)};
