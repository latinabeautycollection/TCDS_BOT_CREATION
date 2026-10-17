const SECRET_KEYS = ["CENSUS_API_KEY","HUD_USER_TOKEN","BEA_API_KEY","DATABASE_URL"] as const;

export function redact(input: unknown, env: NodeJS.ProcessEnv = process.env): string {
  let s = input instanceof Error ? `${input.name}: ${input.message}` : String(input);
  for (const key of SECRET_KEYS) {
    const val = env[key];
    if (val && val.length >= 4) {
      s = s.split(val).join("[REDACTED]");
      try { s = s.split(encodeURIComponent(val)).join("[REDACTED]"); } catch {}
    }
  }
  s = s.replace(/postgres(?:ql)?:\/\/([^:@/]+):([^@/]+)@/gi, "postgresql://$1:[REDACTED]@");
  s = s.replace(/([?&](?:key|api_key|apikey|token|userId|userid)=)[^&\s]+/gi, "$1[REDACTED]");
  s = s.replace(/(Bearer\s+)[A-Za-z0-9._~+\/-]+/gi, "$1[REDACTED]");
  return s.slice(0, 8000);
}
