import test from "node:test";
import assert from "node:assert/strict";
import { canonicalizeSamsClubProductUrl, discoverSamsClubProducts, extractSamsClubProductUrls, findUnreturnedSamsClubInputs } from "../src/discovery.js";
import { SamsClubRecordSchema } from "../src/types.js";
import { normalizePrices } from "../src/util.js";

const seed = "https://www.samsclub.com/cp/electronics/1086";

test("extracts canonical unique Sam's Club PDP URLs from hydration JSON", () => {
  const html = String.raw`{"canonicalUrl":"/ip/TCL-TV/16809001824?classType=REGULAR"}{"canonicalUrl":"/ip/TCL-TV/16809001824?variant=x"}{"canonicalUrl":"/browse/not-a-product/1087"}`;
  assert.deepEqual(extractSamsClubProductUrls(html, seed), ["https://www.samsclub.com/ip/TCL-TV/16809001824"]);
  assert.equal(canonicalizeSamsClubProductUrl("/ip/TCL-TV/16809001824?x=1", seed), "https://www.samsclub.com/ip/TCL-TV/16809001824");
});

test("discovers unique products up to the global limit", async () => {
  const pages = [
    String.raw`{"canonicalUrl":"/ip/One/1"}{"canonicalUrl":"/ip/Two/2"}`,
    String.raw`{"canonicalUrl":"/ip/Two/2"}{"canonicalUrl":"/ip/Three/3"}`
  ];
  let index = 0;
  const products = await discoverSamsClubProducts([seed, `${seed}?next=1`], async () => pages[index++]!, 3);
  assert.deepEqual(products.map(product => product.url), [
    "https://www.samsclub.com/ip/One/1",
    "https://www.samsclub.com/ip/Two/2",
    "https://www.samsclub.com/ip/Three/3"
  ]);
});

test("rejects disguised HTTP-200 rate-limit bodies", async () => {
  await assert.rejects(
    discoverSamsClubProducts([seed], async () => "A global adaptive rate limit has been applied. Please retry in a few seconds.", 1),
    /SAMSCLUB_DISCOVERY_RATE_LIMITED/
  );
});

test("accounts for requested inputs omitted from a provider snapshot", () => {
  const requested = ["https://www.samsclub.com/ip/One/1", "https://www.samsclub.com/ip/Two/2"];
  assert.deepEqual(findUnreturnedSamsClubInputs(requested, [{ input: { url: requested[0] }, item_id: "1" }]), [requested[1]]);
});

test("accepts nullable Bright Data array fields", () => {
  const parsed = SamsClubRecordSchema.parse({
    url: "https://www.samsclub.com/ip/One/1",
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

test("normalizes equal, sale, and reversed Sam's Club prices", () => {
  assert.deepEqual(normalizePrices("$327.99", null), { regular: 327.99, sale: null, effective: 327.99 });
  assert.deepEqual(normalizePrices("$699.99", "$527.99"), { regular: 699.99, sale: 527.99, effective: 527.99 });
  assert.deepEqual(normalizePrices("$527.99", "$699.99"), { regular: 699.99, sale: 527.99, effective: 527.99 });
});
