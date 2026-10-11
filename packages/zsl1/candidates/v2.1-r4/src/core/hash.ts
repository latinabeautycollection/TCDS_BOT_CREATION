import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";

export function canonicalJson(value: unknown): string {
  const normalize = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(normalize);
    if (v && typeof v === "object") {
      const out: Record<string, unknown> = {};
      for (const k of Object.keys(v as Record<string, unknown>).sort()) {
        out[k] = normalize((v as Record<string, unknown>)[k]);
      }
      return out;
    }
    return v;
  };
  return JSON.stringify(normalize(value));
}

export function sha256Text(v: string): string {
  return createHash("sha256").update(v, "utf8").digest("hex");
}

export function sha256Canonical(v: unknown): string {
  return sha256Text(canonicalJson(v));
}

export async function sha256File(path: string): Promise<string> {
  const h = createHash("sha256");
  await new Promise<void>((resolve, reject) => {
    const s = createReadStream(path);
    s.on("data", (chunk) => h.update(chunk));
    s.on("error", reject);
    s.on("end", resolve);
  });
  return h.digest("hex");
}
