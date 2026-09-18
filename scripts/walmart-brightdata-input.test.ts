import assert from "node:assert/strict";
import test from "node:test";
import { buildWalmartInput } from "./walmart-brightdata-input.js";

const productUrl = "https://www.walmart.com/ip/test-product/51259338";

test("sends the documented zipcode field with a product URL", () => {
  assert.deepEqual(buildWalmartInput(productUrl, " 10001 "), [
    { url: productUrl, zipcode: "10001" },
  ]);
});

test("fails closed on missing or invalid ZIP and non-Walmart URLs", () => {
  assert.throws(() => buildWalmartInput(productUrl), /WALMART_ZIPCODE/);
  assert.throws(() => buildWalmartInput(productUrl, "1000"), /WALMART_ZIPCODE/);
  assert.throws(
    () => buildWalmartInput("https://example.com/ip/51259338", "10001"),
    /WALMART_PRODUCT_URL/
  );
});
