export function asPgBigIntString(v: unknown, field: string): string {
  const s = String(v ?? '');
  if (!/^-?\d+$/.test(s)) throw new Error(`INVALID_BIGINT:${field}:${s}`);
  return s;
}

export function safeSmallInt(v: unknown, field: string, max = 10_000_000): number {
  const s = asPgBigIntString(v, field);
  const n = Number(s);
  if (!Number.isSafeInteger(n) || Math.abs(n) > max) throw new Error(`UNSAFE_INTEGER:${field}:${s}`);
  return n;
}

export function normalizeDecimal(v: unknown, field: string, scale = 9): string | null {
  if (v === null || v === undefined || v === '') return null;
  const s = String(v).trim();
  if (!/^-?(?:\d+)(?:\.\d+)?$/.test(s)) throw new Error(`INVALID_DECIMAL:${field}:${s}`);
  const neg = s.startsWith('-');
  const body = neg ? s.slice(1) : s;
  const parts = body.split('.');
  let i = parts[0] ?? '0';
  let f = parts[1] ?? '';
  i = i.replace(/^0+(?=\d)/, '') || '0';
  const factor = 10n ** BigInt(scale);
  const keptFraction = f.slice(0, scale).padEnd(scale, '0');
  let scaled = BigInt(i) * factor + BigInt(keptFraction || '0');
  if ((f[scale] ?? '0') >= '5') scaled += 1n;
  i = (scaled / factor).toString();
  f = (scaled % factor).toString().padStart(scale, '0');
  const roundedToZero = scaled === 0n;
  const out = `${neg && !roundedToZero ? '-' : ''}${i}.${f}`;
  return /^-?0\.0+$/.test(out) ? `0.${'0'.repeat(scale)}` : out;
}

export function assertRatioDecimal(v: unknown, field: string, scale = 9): string | null {
  const s = normalizeDecimal(v, field, scale);
  if (s === null) return null;
  const neg = s.startsWith('-');
  const parts = (neg ? s.slice(1) : s).split('.');
  const i = parts[0] ?? '0';
  const f = parts[1] ?? '';
  if (neg || BigInt(i) > 1n || (BigInt(i) === 1n && /[1-9]/.test(f))) {
    throw new Error(`INVALID_HUD_RATIO:${field}:${String(v)}`);
  }
  return s;
}
