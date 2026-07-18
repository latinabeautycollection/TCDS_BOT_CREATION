import assert from "node:assert/strict";
import test from "node:test";
import { BjsRecordSchema } from "../src/types.js";
import {
  canonicalizeBjsProductUrl,
  discoverBjsProducts,
  extractBjsPublicPriceProducts,
  findUnreturnedBjsInputs
} from "../src/discovery.js";

const categoryUrl = "https://www.bjs.com/category/tvs-and-electronics/computers/743";

const html = `
  <div data-index="0"><div data-cnstrc-item-id="341107" data-cnstrc-item-price="349.99">
    <a href="/product/hp-laptop/3000000000005614785?source=grid">HP</a>
    <a href="/product/hp-laptop/3000000000005614785">HP duplicate</a>
  </div></div>
  <div data-index="1"><div data-cnstrc-item-id="355344">
    <p class="display-member-price">Member Only Price</p>
    <a href="/product/ipad-air/3000000000006188279">iPad</a>
  </div></div>
  <div data-index="2"><div data-cnstrc-item-id="340872" data-cnstrc-item-price="$599.99">
    <a href="https://www.bjs.com/product/acer-laptop/3000000000005603303/">Acer</a>
  </div></div>`;

test("canonicalizes BJ's PDP URLs", () => {
  assert.equal(
    canonicalizeBjsProductUrl("/product/hp-laptop/3000000000005614785?x=1", categoryUrl),
    "https://www.bjs.com/product/hp-laptop/3000000000005614785"
  );
  assert.equal(canonicalizeBjsProductUrl("https://example.com/product/x/1", categoryUrl), null);
});

test("extracts public-price cards and excludes member-only cards", () => {
  assert.deepEqual(extractBjsPublicPriceProducts(html, categoryUrl), [
    { url: "https://www.bjs.com/product/hp-laptop/3000000000005614785", listingPrice: 349.99 },
    { url: "https://www.bjs.com/product/acer-laptop/3000000000005603303", listingPrice: 599.99 }
  ]);
});

test("discovers unique products up to the global limit", async () => {
  const products = await discoverBjsProducts([categoryUrl, `${categoryUrl}/more`], async () => html, 2);
  assert.equal(products.length, 2);
  assert.equal(new Set(products.map(product => product.url)).size, 2);
});

test("accepts nullable Bright Data array fields", () => {
  const row = BjsRecordSchema.parse({
    url: "https://www.bjs.com/product/x/3000000000000000001",
    item_id: "1",
    title: "Product",
    price: "$10.00",
    category_tree: null,
    additional_image_urls: null,
    variant_attributes: null,
    variants: null,
    reviews: null,
    target_countries: null,
    category_urls: null
  });
  assert.deepEqual(row.category_tree, []);
  assert.deepEqual(row.additional_image_urls, []);
  assert.deepEqual(row.variants, []);
  assert.deepEqual(row.category_urls, []);
});

test("accounts for requested inputs omitted from a provider snapshot", () => {
  const first = "https://www.bjs.com/product/first/3000000000000000001";
  const second = "https://www.bjs.com/product/second/3000000000000000002";
  const third = "https://www.bjs.com/product/third/3000000000000000003";
  assert.deepEqual(
    findUnreturnedBjsInputs(
      [first, second, third],
      [{ input: { url: `${first}/` }, title: "First" }, { input: { url: second }, error_code: "blocked" }]
    ),
    [third]
  );
});
