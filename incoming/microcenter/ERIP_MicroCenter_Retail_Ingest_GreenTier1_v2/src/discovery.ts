import type { BrightDataClient } from "./brightdata.js";
import type { Logger } from "./logger.js";
import { sleep } from "./util.js";

export function isSearchOrCategoryUrl(url: string): boolean {
  const u = url.toLowerCase();
  return (
    u.includes("/search/") ||
    u.includes("search_results.aspx") ||
    u.includes("ntt=") ||
    u.includes("n=")
  );
}

export function getPaginatedUrl(baseUrl: string, page: number): string {
  if (page === 1) return baseUrl;
  try {
    const u = new URL(baseUrl);
    const rpp = parseInt(u.searchParams.get("rpp") ?? "24", 10);
    const offset = (page - 1) * rpp;
    u.searchParams.set("Nao", String(offset));
    return u.toString();
  } catch {
    const separator = baseUrl.includes("?") ? "&" : "?";
    return `${baseUrl}${separator}Nao=${(page - 1) * 24}`;
  }
}

export function extractProductUrlsFromHtml(html: string): string[] {
  const urls = new Set<string>();
  // Match path pattern: /product/123456/slug-name
  const regex = /\/product\/(\d+)(?:\/([^"'#>\s?&]*))?/gi;
  let match;
  while ((match = regex.exec(html)) !== null) {
    const sku = match[1];
    const slug = match[2] || "";
    const absoluteUrl = `https://www.microcenter.com/product/${sku}${slug ? "/" + slug : ""}`;
    urls.add(absoluteUrl);
  }
  return Array.from(urls);
}

export async function discoverProductUrls(
  bright: BrightDataClient,
  searchUrls: string[],
  limitPerInput: number,
  log: Logger
): Promise<string[]> {
  const allUrls = new Set<string>();

  for (const searchUrl of searchUrls) {
    log.info({ url: searchUrl }, "discovery_query_started");
    let page = 1;
    let totalFoundForQuery = 0;
    let consecutiveEmptyPages = 0;

    // Safety check to ensure we do not loop infinitely
    while (totalFoundForQuery < limitPerInput && consecutiveEmptyPages < 2 && page <= 50) {
      const pageUrl = getPaginatedUrl(searchUrl, page);
      log.info({ page, pageUrl }, "discovery_page_fetching");
      try {
        const html = await bright.fetchWebUnlockerHtml(pageUrl);
        const productUrls = extractProductUrlsFromHtml(html);
        log.info({ page, found: productUrls.length }, "discovery_page_fetched");

        if (productUrls.length === 0) {
          consecutiveEmptyPages++;
          page++;
          continue;
        }

        consecutiveEmptyPages = 0;
        let newUrlsAdded = 0;
        for (const productUrl of productUrls) {
          if (!allUrls.has(productUrl)) {
            allUrls.add(productUrl);
            newUrlsAdded++;
            totalFoundForQuery++;
          }
          if (totalFoundForQuery >= limitPerInput) break;
        }

        log.info({ page, newUrls: newUrlsAdded, totalQuery: totalFoundForQuery }, "discovery_page_summary");
        if (newUrlsAdded === 0) {
          log.info("discovery_no_new_urls_stop");
          break;
        }

        page++;
        await sleep(1000);
      } catch (error) {
        log.error({ pageUrl, error: error instanceof Error ? error.message : String(error) }, "discovery_page_failed");
        break;
      }
    }
  }

  return Array.from(allUrls);
}
