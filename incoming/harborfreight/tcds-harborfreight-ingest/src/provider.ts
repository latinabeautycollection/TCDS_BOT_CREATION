export function providerError(row: unknown): { code: string; message: string } | null {
  if (!row || typeof row !== 'object') return null;
  const value = row as Record<string, unknown>;
  const error = typeof value.error === 'string' ? value.error.trim() : '';
  const errorCode = typeof value.error_code === 'string' ? value.error_code.trim() : '';
  if (!error && !errorCode) return null;
  return {
    code: `PROVIDER_${errorCode || 'ERROR'}`,
    message: error || errorCode || 'Bright Data provider error'
  };
}
