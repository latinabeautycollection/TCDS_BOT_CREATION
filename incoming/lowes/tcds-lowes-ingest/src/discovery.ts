export type LowesProductInput = { url: string };

export function canonicalizeLowesPdpUrl(value: string, baseUrl: string): string | null {
  try {
    const url = new URL(value.replace(/&amp;/gi, "&"), baseUrl);
    if (!/^(?:www\.)?lowes\.com$/i.test(url.hostname)) return null;
    if (!/\/pd\/[^/]+\/\d+\/?$/i.test(url.pathname)) return null;
    url.protocol = "https:";
    url.hostname = "www.lowes.com";
    url.search = "";
    url.hash = "";
    url.pathname = url.pathname.replace(/\/+$/, "");
    return url.href;
  } catch {
    return null;
  }
}

export function extractLowesPdpUrls(html: string, baseUrl: string): string[] {
  const urls = new Set<string>();
  for (const match of html.matchAll(/\bhref=["']([^"']+)["']/gi)) {
    const canonical = canonicalizeLowesPdpUrl(match[1]!, baseUrl);
    if (canonical) urls.add(canonical);
  }
  return [...urls];
}

export async function discoverLowesProducts(
  seedUrls: string[],
  fetchHtml: (url: string) => Promise<string>,
  limit: number
): Promise<LowesProductInput[]> {
  const products = new Map<string, LowesProductInput>();
  for (const seedUrl of seedUrls) {
    const html = await fetchHtml(seedUrl);
    for (const url of extractLowesPdpUrls(html, seedUrl)) {
      products.set(url, { url });
      if (products.size >= limit) return [...products.values()];
    }
  }
  return [...products.values()];
}

export function findUnreturnedLowesInputs(requested: string[], rows: unknown[]): string[] {
  const returned = new Set<string>();
  for (const raw of rows) {
    if (!raw || typeof raw !== "object") continue;
    const row = raw as Record<string, unknown>;
    const input = row.input;
    const candidate = input && typeof input === "object"
      ? (input as Record<string, unknown>).url
      : row.url;
    if (typeof candidate !== "string") continue;
    const canonical = canonicalizeLowesPdpUrl(candidate, candidate);
    if (canonical) returned.add(canonical);
  }
  return requested.filter(url => !returned.has(url));
}
