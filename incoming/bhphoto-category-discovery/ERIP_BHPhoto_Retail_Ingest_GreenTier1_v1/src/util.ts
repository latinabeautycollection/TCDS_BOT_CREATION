import { createHash, randomUUID } from "node:crypto";

export const uuid = () => randomUUID();
export const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));

export function sha256(value: unknown): string {
  const text = typeof value === "string" ? value : stableStringify(value);
  return createHash("sha256").update(text).digest("hex");
}

export function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  const obj = value as Record<string, unknown>;
  return `{${Object.keys(obj).sort().map(k => `${JSON.stringify(k)}:${stableStringify(obj[k])}`).join(",")}}`;
}

export function chunk<T>(values: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let i = 0; i < values.length; i += size) result.push(values.slice(i, i + size));
  return result;
}

export function first(obj: Record<string, unknown>, keys: string[]): unknown {
  for (const key of keys) if (obj[key] !== undefined && obj[key] !== null) return obj[key];
  return undefined;
}
export function text(v: unknown): string | null {
  if (typeof v === "string" && v.trim()) return v.trim();
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return null;
}
export function number(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v !== "string") return null;
  const n = Number(v.replace(/[$,%\s,]/g, ""));
  return Number.isFinite(n) ? n : null;
}
export function integer(v: unknown): number | null {
  const n = number(v);
  return n === null ? null : Math.trunc(n);
}
export function bool(v: unknown): boolean | null {
  if (typeof v === "boolean") return v;
  if (typeof v === "number") return v !== 0;
  if (typeof v !== "string") return null;
  const s = v.trim().toLowerCase();
  if (["true","yes","1","in stock","available"].includes(s)) return true;
  if (["false","no","0","out of stock","unavailable"].includes(s)) return false;
  return null;
}
