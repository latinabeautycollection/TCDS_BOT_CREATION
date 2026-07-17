import { money } from "./util.js";

export type CostcoInput = { url: string };
export type CostcoPdpOffer = {
  price: number;
  currency: string;
  availability: string | null;
};

const PDP_PATH = /\.product\.\d+\.html$/i;

export function canonicalizeCostcoProductUrl(value: string, baseUrl: string): string | null {
  try {
    const url = new URL(value.replace(/&amp;/gi, "&"), baseUrl);
    const host = url.hostname.toLowerCase();
    if (url.protocol !== "https:" || (host !== "costco.com" && !host.endsWith(".costco.com"))) return null;
    if (!PDP_PATH.test(url.pathname)) return null;
    url.protocol = "https:";
    url.hostname = "www.costco.com";
    url.search = "";
    url.hash = "";
    return url.href;
  } catch {
    return null;
  }
}

export function extractCostcoProductUrls(html: string, baseUrl: string): string[] {
  const urls = new Set<string>();
  for (const match of html.matchAll(/\bhref=["']([^"']+)["']/gi)) {
    const url = canonicalizeCostcoProductUrl(match[1]!, baseUrl);
    if (url) urls.add(url);
  }
  return [...urls];
}

function schemaType(value: unknown): string[] {
  if (typeof value === "string") return [value.toLowerCase()];
  if (Array.isArray(value)) return value.filter((item): item is string => typeof item === "string").map(item => item.toLowerCase());
  return [];
}

function offerFromProduct(product: Record<string, unknown>): CostcoPdpOffer | null {
  const offers = Array.isArray(product.offers) ? product.offers : [product.offers];
  for (const value of offers) {
    if (!value || typeof value !== "object" || Array.isArray(value)) continue;
    const offer = value as Record<string, unknown>;
    const price = money(offer.price ?? offer.lowPrice);
    if (price == null) continue;
    const availabilityValue = typeof offer.availability === "string" ? offer.availability : null;
    return {
      price,
      currency: typeof offer.priceCurrency === "string" ? offer.priceCurrency.toUpperCase() : "USD",
      availability: availabilityValue?.split("/").at(-1)?.toLowerCase() ?? null
    };
  }
  return null;
}

function findProductOffer(value: unknown): CostcoPdpOffer | null {
  if (Array.isArray(value)) {
    for (const item of value) {
      const offer = findProductOffer(item);
      if (offer) return offer;
    }
    return null;
  }
  if (!value || typeof value !== "object") return null;
  const object = value as Record<string, unknown>;
  if (schemaType(object["@type"]).includes("product")) {
    const offer = offerFromProduct(object);
    if (offer) return offer;
  }
  for (const nested of Object.values(object)) {
    const offer = findProductOffer(nested);
    if (offer) return offer;
  }
  return null;
}

export function extractCostcoPdpOffer(html: string): CostcoPdpOffer | null {
  for (const match of html.matchAll(/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
    try {
      const offer = findProductOffer(JSON.parse(match[1]!));
      if (offer) return offer;
    } catch {
      // Ignore malformed unrelated JSON-LD blocks and continue looking for Product data.
    }
  }
  return null;
}

export async function discoverCostcoInputs(
  seeds: string[],
  fetchHtml: (url: string) => Promise<string>,
  limit: number
): Promise<CostcoInput[]> {
  const products = new Set<string>();
  for (const seed of seeds) {
    const direct = canonicalizeCostcoProductUrl(seed, seed);
    if (direct) products.add(direct);
    else {
      const html = await fetchHtml(seed);
      for (const url of extractCostcoProductUrls(html, seed)) {
        products.add(url);
        if (products.size >= limit) break;
      }
    }
    if (products.size >= limit) break;
  }
  if (!products.size) throw new Error("COSTCO_DISCOVERY_EMPTY");
  return [...products].slice(0, limit).map(url => ({ url }));
}
