import pino from "pino"; import { env } from "../config/env.js";
export const logger=pino({level:env.LOG_LEVEL,redact:{paths:['token','authorization','req.headers.authorization','BRIGHTDATA_API_TOKEN'],censor:'[REDACTED]'}});
