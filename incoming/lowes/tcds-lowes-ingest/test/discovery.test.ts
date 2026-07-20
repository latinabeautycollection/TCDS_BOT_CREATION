import test from "node:test";
import assert from "node:assert/strict";
import {
  canonicalizeLowesPdpUrl,
  discoverLowesProducts,
  extractLowesPdpUrls,
  findUnreturnedLowesInputs
} from "../src/discovery.js";
import { LowesRecordSchema } from "../src/types.js";
import { availability, htmlLooks404, normalizeLowesPrices } from "../src/util.js";

const base = "https://www.lowes.com/pl/power-tools/4294607842";
const first = "https://www.lowes.com/pd/DEWALT-Tool/5014148639";
const second = "https://www.lowes.com/pd/Bosch-Tool/5013256931";

test("canonicalizes Lowe's PDP URLs and rejects navigation links", () => {
  assert.equal(
    canonicalizeLowesPdpUrl("/pd/DEWALT-Tool/5014148639?store=123#details", base),
    first
  );
  assert.equal(canonicalizeLowesPdpUrl("/pl/power-tools/4294607842", base), null);
  assert.deepEqual(
    extractLowesPdpUrls(
      `<a href="/pd/DEWALT-Tool/5014148639?x=1"></a><a href="${first}"></a>`,
      base
    ),
    [first]
  );
});

test("discovers unique products up to the global limit", async () => {
  const pageOne = `${base}?offset=0`;
  const pageTwo = `${base}?offset=24`;
  const pages: Record<string, string> = {
    [pageOne]: `<a href="${first}"></a>`,
    [pageTwo]: `<a href="${first}"></a><a href="${second}"></a>`
  };
  const products = await discoverLowesProducts([pageOne, pageTwo], async url => pages[url]!, 2);
  assert.deepEqual(products, [{ url: first }, { url: second }]);
});

test("accounts for requested inputs omitted from a provider snapshot", () => {
  assert.deepEqual(
    findUnreturnedLowesInputs([first, second], [{ input: { url: first } }]),
    [second]
  );
});

test("accepts nullable Lowe's array fields", () => {
  const parsed = LowesRecordSchema.parse({
    url: first,
    marketplace_pn: 5014148639,
    product_name: "DEWALT Tool",
    badges: null,
    availability: null,
    image_urls: null,
    additional_image_urls: null,
    category_tree: null,
    nai_category_tree: null,
    variant_attributes: null,
    variants: null
  });
  assert.equal(parsed.marketplace_pn, "5014148639");
  assert.deepEqual(parsed.image_urls, []);
  assert.deepEqual(parsed.variant_attributes, []);
});

test("normalizes equal, sale, and reversed Lowe's price fields", () => {
  assert.deepEqual(normalizeLowesPrices(249, 169, "$249.00", "$169.00"), {
    regular: 249,
    sale: 169,
    effective: 169
  });
  assert.deepEqual(normalizeLowesPrices(349, 349, "$349.00", null), {
    regular: 349,
    sale: null,
    effective: 349
  });
  assert.deepEqual(normalizeLowesPrices("$119.00", "$259.00"), {
    regular: 259,
    sale: 119,
    effective: 119
  });
});

test("classifies unavailable inventory before the available substring", () => {
  assert.equal(availability("unavailable"), "out_of_stock");
  assert.equal(availability("out_of_stock"), "out_of_stock");
  assert.equal(availability("available"), "in_stock");
});

test("does not treat incidental 404 script data as a missing page", () => {
  assert.equal(htmlLooks404(`<html><script>const status = 404;</script></html>`), false);
  assert.equal(htmlLooks404(`<html><title>404 Page Not Found</title></html>`), true);
});
