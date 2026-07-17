import pino from "pino";
import type { AppConfig } from "./config.js";

export function createLogger(config: AppConfig) {
  return pino({
    level: config.LOG_LEVEL,
    base: {
      service: "erip-bhphoto-retail-ingest",
      environment: config.ERIP_ENVIRONMENT,
      worker_id: config.ERIP_WORKER_ID
    },
    redact: {
      paths: [
        "BRIGHT_DATA_API_TOKEN",
        "DATABASE_URL",
        "*.authorization",
        "*.password",
        "*.token",
        "*.api_key"
      ],
      censor: "[REDACTED]"
    },
    timestamp: pino.stdTimeFunctions.isoTime
  });
}
export type Logger = ReturnType<typeof createLogger>;
