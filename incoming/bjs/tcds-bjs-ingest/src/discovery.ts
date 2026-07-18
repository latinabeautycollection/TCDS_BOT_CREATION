import { money } from "./util.js";

export type BjsDiscoveredProduct = {
  url: string;
  listingPrice: number;
};

const PRODUCT_PATH = /^\/product\/.+\/\d+\/?$/i;

export function canonicalizeBjsProductUrl(value: string, baseUrl: string): string | null {
  try {
    const url = new URL(value.replace(/&amp;/gi, "&"), baseUrl);
    const host = url.hostname.toLowerCase();
    if (url.protocol !== "https:" || (host !== "bjs.com" && !host.endsWith(".bjs.com"))) return null;
    if (!PRODUCT_PATH.test(url.pathname)) return null;
    url.protocol = "https:";
    url.hostname = "www.bjs.com";
    url.pathname = url.pathname.replace(/\/+$/, "");
    url.search = "";
    url.hash = "";
    return url.href;
  } catch {
    return null;
  }
}

export function extractBjsPublicPriceProducts(html: string, baseUrl: string): BjsDiscoveredProduct[] {
  const products = new Map<string, BjsDiscoveredProduct>();
  const cards = html.split(/<div\s+data-index=["'][^"']+["']/i).slice(1);

  for (const card of cards) {
    const priceMatch = card.match(/data-cnstrc-item-price=["']([^"']+)["']/i);
    if (!priceMatch) continue;
    const listingPrice = money(priceMatch[1]);
    if (listingPrice == null) continue;

    for (const link of card.matchAll(/\bhref=["']([^"']+)["']/gi)) {
      const url = canonicalizeBjsProductUrl(link[1]!, baseUrl);
      if (!url) continue;
      products.set(url, { url, listingPrice });
      break;
    }
  }

  return [...products.values()];
}

export async function discoverBjsProducts(
  seeds: string[],
  fetchHtml: (url: string) => Promise<string>,
  limit: number
): Promise<BjsDiscoveredProduct[]> {
  const products = new Map<string, BjsDiscoveredProduct>();
  for (const seed of seeds) {
    const html = await fetchHtml(seed);
    if (!html.trim()) throw new Error(`BJS_DISCOVERY_EMPTY_RESPONSE:${seed}`);
    for (const product of extractBjsPublicPriceProducts(html, seed)) {
      products.set(product.url, product);
      if (products.size >= limit) break;
    }
    if (products.size >= limit) break;
  }
  if (!products.size) throw new Error("BJS_DISCOVERY_EMPTY");
  return [...products.values()].slice(0, limit);
}

export function findUnreturnedBjsInputs(requested: string[], rows: unknown[]): string[] {
  const returned = new Set<string>();
  for (const value of rows) {
    if (!value || typeof value !== "object") continue;
    const row = value as { input?: { url?: unknown }; url?: unknown };
    const candidate = typeof row.input?.url === "string"
      ? row.input.url
      : typeof row.url === "string"
        ? row.url
        : null;
    if (!candidate) continue;
    const canonical = canonicalizeBjsProductUrl(candidate, candidate);
    if (canonical) returned.add(canonical);
  }
  return requested.filter(url => {
    const canonical = canonicalizeBjsProductUrl(url, url);
    return canonical == null || !returned.has(canonical);
  });
}
