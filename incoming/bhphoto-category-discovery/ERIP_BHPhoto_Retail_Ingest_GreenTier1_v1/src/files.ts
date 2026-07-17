import { readFile } from "node:fs/promises";

export async function readRecordFile(path: string): Promise<unknown[]> {
  const body = (await readFile(path, "utf8")).trim();
  if (!body) return [];
  if (path.endsWith(".ndjson") || path.endsWith(".jsonl")) {
    return body.split(/\r?\n/).filter(Boolean).map((line, i) => {
      try { return JSON.parse(line); }
      catch { throw new Error(`Invalid NDJSON/JSONL at line ${i + 1}`); }
    });
  }
  const parsed: unknown = JSON.parse(body);
  if (Array.isArray(parsed)) return parsed;
  if (parsed && typeof parsed === "object") {
    const o = parsed as Record<string, unknown>;
    if (Array.isArray(o.data)) return o.data;
    if (Array.isArray(o.results)) return o.results;
  }
  return [parsed];
}
