import { gunzipSync } from 'node:zlib';

const LOC_PATTERN = /<loc>\s*([^<]+?)\s*<\/loc>/gi;

async function fetchXml(url: string): Promise<string> {
  let response: Response | undefined;
  let lastError: unknown;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      response = await fetch(url, {
        headers: {
          'User-Agent': 'Mozilla/5.0 (compatible; TCDS-Retail-Ingest/1.0)',
          Accept: 'application/xml,text/xml,application/gzip,*/*'
        }
      });
      if (response.ok) break;
      lastError = new Error(`Sears sitemap ${response.status}: ${url}`);
      if (response.status < 500 && response.status !== 429) throw lastError;
    } catch (error) {
      lastError = error;
    }
    if (attempt < 3) await new Promise(resolve => setTimeout(resolve, attempt * 1000));
  }
  if (!response?.ok) throw lastError ?? new Error(`Sears sitemap fetch failed: ${url}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  return bytes[0] === 0x1f && bytes[1] === 0x8b
    ? gunzipSync(bytes).toString('utf8')
    : bytes.toString('utf8');
}

export function extractLocations(xml: string): string[] {
  return [...xml.matchAll(LOC_PATTERN)].map(match =>
    match[1]!.replace(/&amp;/gi, '&').trim()
  );
}

export function canonicalSearsProductUrl(value: string): string | null {
  try {
    const url = new URL(value);
    if (!/^(?:www\.)?sears\.com$/i.test(url.hostname)) return null;
    if (!/\/p-([A-Za-z0-9_-]+)\/?$/i.test(url.pathname)) return null;
    url.protocol = 'https:';
    url.hostname = 'www.sears.com';
    url.search = '';
    url.hash = '';
    url.pathname = url.pathname.replace(/\/+$/, '');
    return url.href;
  } catch {
    return null;
  }
}

export function evenlySample<T>(values: T[], limit: number): T[] {
  if (values.length <= limit) return [...values];
  if (limit <= 1) return values.length ? [values[0]!] : [];
  const selected: T[] = [];
  for (let index = 0; index < limit; index++) {
    selected.push(values[Math.floor(index * (values.length - 1) / (limit - 1))]!);
  }
  return selected;
}

export async function discoverSearsProducts(
  indexUrl: string,
  categories: string[],
  limit: number
): Promise<string[]> {
  const indexLocations = extractLocations(await fetchXml(indexUrl));
  const wanted = categories.map(value => value.trim().toLowerCase()).filter(Boolean);
  const childSitemaps = indexLocations.filter(location => {
    if (/Sitemap_Product_MP_/i.test(location)) return false;
    const name = location.toLowerCase();
    return wanted.some(category =>
      name.includes(`sitemap_product_${category.toLowerCase()}`)
    );
  });

  const categoryProducts = new Map<string, Map<string, string>>();
  for (const sitemapUrl of childSitemaps) {
    const category = wanted.find(value =>
      sitemapUrl.toLowerCase().includes(`sitemap_product_${value}`)
    );
    if (!category) continue;
    const products = categoryProducts.get(category) ?? new Map<string, string>();
    for (const location of extractLocations(await fetchXml(sitemapUrl))) {
      const canonical = canonicalSearsProductUrl(location);
      if (!canonical) continue;
      const itemId = canonical.match(/\/p-([A-Za-z0-9_-]+)$/i)![1]!.toUpperCase();
      products.set(itemId, canonical);
    }
    categoryProducts.set(category, products);
  }

  const perCategory = Math.ceil(limit / Math.max(1, categoryProducts.size));
  const sampled = wanted.map(category =>
    evenlySample([...(categoryProducts.get(category)?.values() ?? [])], perCategory)
  );
  const discovered: string[] = [];
  for (let index = 0; discovered.length < limit; index++) {
    let added = false;
    for (const products of sampled) {
      const product = products[index];
      if (!product) continue;
      discovered.push(product);
      added = true;
      if (discovered.length >= limit) break;
    }
    if (!added) break;
  }
  return discovered;
}
