import test from "node:test";
import assert from "node:assert/strict";
import {
  canonicalizeOfficeDepotProductUrl,
  discoverOfficeDepotProducts,
  extractOfficeDepotPaginationUrls,
  extractOfficeDepotProductUrls,
  findUnreturnedOfficeDepotInputs
} from "../src/discovery.js";
import { OfficeDepotRecordSchema } from "../src/types.js";
import { normalizePrices } from "../src/util.js";

const seed = "https://www.officedepot.com/b/electronics/Featured_Items--On_Sale/N-9021";

test("extracts canonical Office Depot PDP URLs and rejects header products", () => {
  const html = `
    <a data-auid="Header_FlyoutNavigation" href="/a/products/870284/Copies/">Copies</a>
    <a data-auid="OdSearchBrowse_Product" href="/a/products/8933687/Epson-Scanner/?promo=deal">Scanner</a>
    <a href="https://example.com/a/products/123/Bad">Bad</a>`;
  assert.deepEqual(extractOfficeDepotProductUrls(html, seed), [
    "https://www.officedepot.com/a/products/8933687/Epson-Scanner"
  ]);
  assert.equal(canonicalizeOfficeDepotProductUrl("/a/products/8933687/Epson-Scanner/", seed), "https://www.officedepot.com/a/products/8933687/Epson-Scanner");
});

test("extracts Office Depot pagination URLs in page order", () => {
  const html = `<a href="?page=4">4</a><a href="?page=2">2</a><a href="?page=3">3</a>`;
  assert.deepEqual(extractOfficeDepotPaginationUrls(html, seed), [
    `${seed}?page=2`, `${seed}?page=3`, `${seed}?page=4`
  ]);
});

test("discovers products across pagination up to the global limit", async () => {
  const pages = new Map<string, string>([
    [seed, `<a href="/a/products/1/One">One</a><a href="?page=2">2</a>`],
    [`${seed}?page=2`, `<a href="/a/products/2/Two">Two</a><a href="/a/products/3/Three">Three</a>`]
  ]);
  const products = await discoverOfficeDepotProducts([seed], async url => pages.get(url) ?? "", 3);
  assert.deepEqual(products.map(product => product.url), [
    "https://www.officedepot.com/a/products/1/One",
    "https://www.officedepot.com/a/products/2/Two",
    "https://www.officedepot.com/a/products/3/Three"
  ]);
});

test("accounts for requested inputs omitted from a provider snapshot", () => {
  const requested = [
    "https://www.officedepot.com/a/products/1/One",
    "https://www.officedepot.com/a/products/2/Two"
  ];
  assert.deepEqual(findUnreturnedOfficeDepotInputs(requested, [
    { input: { url: requested[0] }, item_id: "1" }
  ]), [requested[1]]);
});

test("accepts nullable Bright Data array fields", () => {
  const parsed = OfficeDepotRecordSchema.parse({
    url: "https://www.officedepot.com/a/products/1/One/",
    item_id: "1",
    title: "One",
    category_tree: null,
    additional_image_urls: null,
    variant_attributes: null,
    variants: null,
    reviews: null,
    target_countries: null,
    category_urls: null
  });
  assert.deepEqual(parsed.category_tree, []);
  assert.deepEqual(parsed.additional_image_urls, []);
});

test("normalizes equal, sale, and reversed Office Depot prices", () => {
  assert.deepEqual(normalizePrices("$242.99", "$242.99"), { regular: 242.99, sale: null, effective: 242.99 });
  assert.deepEqual(normalizePrices("$379.99", "$299.99"), { regular: 379.99, sale: 299.99, effective: 299.99 });
  assert.deepEqual(normalizePrices("$299.99", "$379.99"), { regular: 379.99, sale: 299.99, effective: 299.99 });
});
