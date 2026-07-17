import test from "node:test";
import assert from "node:assert/strict";
import { extractBhPhotoPaginationUrls, extractBhPhotoProductUrls } from "../src/discovery.js";

test("extracts and canonicalizes unique B&H PDP URLs",()=>{
  const html='<a href="/c/product/1864889-REG/apple_mw2u3ll_a_13_ipad_air_m3.html?sts=pi">One</a><a href="https://www.bhphotovideo.com/c/product/1864889-REG/apple_mw2u3ll_a_13_ipad_air_m3.html">Duplicate</a><a href="/c/products/laptops/ci/18818">Category</a>';
  assert.deepEqual(extractBhPhotoProductUrls(html),['https://www.bhphotovideo.com/c/product/1864889-REG/apple_mw2u3ll_a_13_ipad_air_m3.html']);
});

test("extracts B&H pagination URLs in page order",()=>{
  const seed="https://www.bhphotovideo.com/c/buy/wireless/ci/123";
  const html='<a href="/c/buy/wireless/ci/123/pn/3">3</a><a href="/c/buy/wireless/ci/123/pn/2">2</a>';
  assert.deepEqual(extractBhPhotoPaginationUrls(html,seed),[
    "https://www.bhphotovideo.com/c/buy/wireless/ci/123/pn/2",
    "https://www.bhphotovideo.com/c/buy/wireless/ci/123/pn/3"
  ]);
});
