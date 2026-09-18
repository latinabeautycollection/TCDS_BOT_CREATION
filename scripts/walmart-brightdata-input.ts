export function buildWalmartInput(productUrl: string, zipcode?: string) {
  const zip = zipcode?.trim() ?? "";
  if (!/^\d{5}$/.test(zip)) {
    throw new Error("WALMART_ZIPCODE must be a five-digit US ZIP");
  }
  if (!URL.canParse(productUrl)) {
    throw new Error("WALMART_PRODUCT_URL must be a Walmart product URL");
  }
  const url = new URL(productUrl);
  if (
    url.protocol !== "https:" ||
    !["walmart.com", "www.walmart.com"].includes(url.hostname) ||
    !url.pathname.startsWith("/ip/")
  ) {
    throw new Error("WALMART_PRODUCT_URL must be a Walmart product URL");
  }
  return [{ url: url.href, zipcode: zip }];
}
