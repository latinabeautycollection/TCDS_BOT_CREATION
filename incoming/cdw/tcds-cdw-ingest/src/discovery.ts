export type DiscoveredCDWProduct = { url: string };

export function extractCDWProductUrls(html: string, baseUrl: string): DiscoveredCDWProduct[] {
  const products = new Map<string, string>();

  for (const match of html.matchAll(/\bhref=["']([^"']+)["']/gi)) {
    try {
      const href = match[1];
      if (!href) continue;

      const url = new URL(href.replace(/&amp;/gi, "&"), baseUrl);

      if (
        /^(?:www\.)?cdw\.com$/i.test(url.hostname) &&
        /\/product\/[^/]+\/\d+\/?$/i.test(url.pathname)
      ) {
        const itemId = url.pathname.match(/\/(\d+)\/?$/)?.[1];
        if (!itemId) continue;

        url.protocol = "https:";
        url.hostname = "www.cdw.com";
        url.search = "";
        url.hash = "";
        url.pathname = url.pathname.replace(/\/+$/, "");

        products.set(itemId, url.href);
      }
    } catch {
      // Ignore malformed relative URLs in page chrome.
    }
  }

  return [...products.values()].map(url => ({ url }));
}

export async function discoverCDWProducts(
  seedUrls: string[],
  fetchCategoryHtml: (url: string) => Promise<string>,
  limit: number
): Promise<DiscoveredCDWProduct[]> {
  const products = new Map<string, string>();

  for (const seedUrl of seedUrls) {
    if (products.size >= limit) break;

    const html = await fetchCategoryHtml(seedUrl);
    const discovered = extractCDWProductUrls(html, seedUrl);

    for (const product of discovered) {
      const itemId = product.url.match(/\/(\d+)$/)?.[1];
      if (!itemId || products.has(itemId)) continue;

      products.set(itemId, product.url);
      if (products.size >= limit) break;
    }
  }

  return [...products.values()].map(url => ({ url }));
}
