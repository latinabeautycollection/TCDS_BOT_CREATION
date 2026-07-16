import "dotenv/config";
import { z } from "zod";

const boolFromEnv = z.preprocess((value) => {
  if (typeof value !== "string") return value;
  return ["1", "true", "yes", "on"].includes(value.toLowerCase());
}, z.boolean());

const EnvSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("production"),
  LOG_LEVEL: z.enum(["trace", "debug", "info", "warn", "error", "fatal"]).default("info"),
  BRIGHT_DATA_API_TOKEN: z.string().min(1),
  BRIGHT_DATA_DATASET_ID: z.string().min(1).default("gd_mkckexq2uquhupguv"),
  BRIGHT_DATA_WEB_UNLOCKER_ZONE: z.string().optional(),
  BRIGHT_DATA_BASE_URL: z.string().url().default("https://api.brightdata.com"),
  BRIGHT_DATA_LIMIT_PER_INPUT: z.coerce.number().int().positive().max(10000).default(1000),
  BRIGHT_DATA_INCLUDE_ERRORS: boolFromEnv.default(true),
  BRIGHT_DATA_NOTIFY: boolFromEnv.default(false),
  BRIGHT_DATA_HTTP_TIMEOUT_MS: z.coerce.number().int().min(1000).default(60000),
  BRIGHT_DATA_MAX_HTTP_RETRIES: z.coerce.number().int().min(0).max(10).default(5),
  BRIGHT_DATA_POLL_INTERVAL_MS: z.coerce.number().int().min(1000).default(10000),
  BRIGHT_DATA_MAX_WAIT_MS: z.coerce.number().int().min(60000).default(7200000),
  DATABASE_URL: z.string().min(20),
  DATABASE_SSL: boolFromEnv.default(true),
  DATABASE_POOL_MAX: z.coerce.number().int().min(1).max(20).default(5),
  DATABASE_STATEMENT_TIMEOUT_MS: z.coerce.number().int().min(1000).default(60000),
  DATABASE_LOCK_TIMEOUT_MS: z.coerce.number().int().min(1000).default(10000),
  RETAIL_SCHEMA: z.string().regex(/^[a-z_][a-z0-9_]*$/).default("retail"),
  RETAIL_PLATFORM_CODE: z.string().default("microcenter"),
  RETAIL_SOURCE_NAME: z.string().default("Micro Center"),
  INGEST_BATCH_SIZE: z.coerce.number().int().min(1).max(1000).default(250),
  INGEST_STORE_RAW: boolFromEnv.default(true),
  INGEST_NORMALIZE: boolFromEnv.default(true),
  INGEST_MIN_EVIDENCE_CONFIDENCE: z.coerce.number().min(0).max(1).default(0.50),
  INGEST_MAX_QUARANTINE_RATE: z.coerce.number().min(0).max(1).default(0.20),
  INGEST_MAX_DUPLICATE_RATE: z.coerce.number().min(0).max(1).default(0.95),
  ERIP_ENVIRONMENT: z.string().default("production"),
  ERIP_WORKER_ID: z.string().default("microcenter-ingest-01")
});

export type AppConfig = z.infer<typeof EnvSchema>;

export function loadConfig(): AppConfig {
  const result = EnvSchema.safeParse(process.env);
  if (!result.success) {
    const detail = result.error.issues.map(i => `${i.path.join(".")}: ${i.message}`).join("; ");
    throw new Error(`Configuration validation failed: ${detail}`);
  }
  return result.data;
}
