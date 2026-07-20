export type OfficeDepotDiscoveredProduct = { url: string };

const PRODUCT_PATH = /\/a\/products\/(\d+)(?:\/[^?#]*)?\/?$/i;

export function canonicalizeOfficeDepotProductUrl(value: string, baseUrl: string): string | null {
  try {
    const url = new URL(value.replace(/&amp;/gi, "&"), baseUrl);
    const host = url.hostname.toLowerCase();
    if (url.protocol !== "https:" || (host !== "officedepot.com" && !host.endsWith(".officedepot.com"))) return null;
    if (!PRODUCT_PATH.test(url.pathname)) return null;
    url.protocol = "https:";
    url.hostname = "www.officedepot.com";
    url.pathname = url.pathname.replace(/\/+$/, "");
    url.search = "";
    url.hash = "";
    return url.href;
  } catch {
    return null;
  }
}

export function extractOfficeDepotProductUrls(html: string, baseUrl: string): string[] {
  const urls = new Set<string>();
  for (const match of html.matchAll(/<a\b([^>]*?)href=["']([^"']+)["']([^>]*)>/gi)) {
    const context = `${match[1]} ${match[3]} ${match[2]}`;
    if (/Header_|servicesheader|cpdheader|FlyoutNavigation/i.test(context)) continue;
    const url = canonicalizeOfficeDepotProductUrl(match[2]!, baseUrl);
    if (url) urls.add(url);
  }
  return [...urls];
}

export function extractOfficeDepotPaginationUrls(html: string, baseUrl: string): string[] {
  const pages = new Map<number, string>();
  for (const match of html.matchAll(/\bhref=["']([^"']+)["']/gi)) {
    try {
      const url = new URL(match[1]!.replace(/&amp;/gi, "&"), baseUrl);
      const host = url.hostname.toLowerCase();
      const page = Number(url.searchParams.get("page"));
      if ((host === "officedepot.com" || host.endsWith(".officedepot.com")) && Number.isInteger(page) && page > 1) {
        url.protocol = "https:";
        url.hostname = "www.officedepot.com";
        url.hash = "";
        pages.set(page, url.href);
      }
    } catch {}
  }
  return [...pages.entries()].sort((a, b) => a[0] - b[0]).map(([, url]) => url);
}

export async function discoverOfficeDepotProducts(
  seeds: string[], fetchHtml: (url: string) => Promise<string>, limit: number
): Promise<OfficeDepotDiscoveredProduct[]> {
  const products = new Set<string>();
  for (const seed of seeds) {
    const queue = [seed];
    const visited = new Set<string>();
    while (queue.length && products.size < limit) {
      const pageUrl = queue.shift()!;
      if (visited.has(pageUrl)) continue;
      visited.add(pageUrl);
      const html = await fetchHtml(pageUrl);
      if (!html.trim()) throw new Error(`OFFICE_DEPOT_DISCOVERY_EMPTY_RESPONSE:${pageUrl}`);
      for (const url of extractOfficeDepotProductUrls(html, pageUrl)) {
        products.add(url);
        if (products.size >= limit) break;
      }
      if (visited.size === 1 && products.size < limit) {
        for (const url of extractOfficeDepotPaginationUrls(html, pageUrl)) queue.push(url);
      }
    }
    if (products.size >= limit) break;
  }
  if (!products.size) throw new Error("OFFICE_DEPOT_DISCOVERY_EMPTY");
  return [...products].slice(0, limit).map(url => ({ url }));
}

export function findUnreturnedOfficeDepotInputs(requested: string[], rows: unknown[]): string[] {
  const returned = new Set<string>();
  for (const value of rows) {
    if (!value || typeof value !== "object") continue;
    const row = value as { input?: { url?: unknown }; url?: unknown };
    const candidate = typeof row.input?.url === "string" ? row.input.url : typeof row.url === "string" ? row.url : null;
    if (!candidate) continue;
    const canonical = canonicalizeOfficeDepotProductUrl(candidate, candidate);
    if (canonical) returned.add(canonical);
  }
  return requested.filter(url => {
    const canonical = canonicalizeOfficeDepotProductUrl(url, url);
    return canonical == null || !returned.has(canonical);
  });
}
