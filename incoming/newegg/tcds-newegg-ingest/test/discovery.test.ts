import assert from "node:assert/strict";
import test from "node:test";
import { NeweggRecordSchema } from "../src/types.js";
import { normalizePrices } from "../src/util.js";
import {
  canonicalizeNeweggProductUrl,
  discoverNeweggProducts,
  extractNeweggProductUrls,
  findUnreturnedNeweggInputs
} from "../src/discovery.js";

const category = "https://www.newegg.com/Cell-Phones/Category/ID-450";
const first = "https://www.newegg.com/apple-phone/p/N82E16875827187";
const second = "https://www.newegg.com/p/19J-001R-00003";
const html = `<a href="/p/pl">nav</a><a href="${first}?x=1">one</a><a href="/p/19J-001R-00003/">two</a><a href="${first}">duplicate</a>`;

test("extracts canonical unique Newegg PDP URLs and rejects navigation links",()=>{
  assert.deepEqual(extractNeweggProductUrls(html,category),[first,second]);
  assert.equal(canonicalizeNeweggProductUrl("/p/pl",category),null);
});

test("discovers products up to the global limit",async()=>{
  const products=await discoverNeweggProducts([category,`${category}/more`],async()=>html,2);
  assert.deepEqual(products,[{url:first},{url:second}]);
});

test("accounts for inputs omitted from the provider snapshot",()=>{
  assert.deepEqual(findUnreturnedNeweggInputs([first,second],[{input:{url:`${first}/`}}]),[second]);
});

test("accepts nullable Bright Data array fields",()=>{
  const row=NeweggRecordSchema.parse({url:first,item_id:"1",variant_id:"v1",title:"Phone",price:"$10",category_tree:null,additional_image_urls:null,variant_attributes:null,variants:null,reviews:null,target_countries:null,category_urls:null});
  assert.deepEqual(row.category_tree,[]);
  assert.deepEqual(row.variants,[]);
  assert.deepEqual(row.category_urls,[]);
});

test("normalizes equal, sale, and reversed Newegg price fields",()=>{
  assert.deepEqual(normalizePrices("$449.99","$449.99"),{regular:449.99,sale:null,effective:449.99});
  assert.deepEqual(normalizePrices("$599.99","$499.99"),{regular:599.99,sale:499.99,effective:499.99});
  assert.deepEqual(normalizePrices("$499.99","$599.99"),{regular:599.99,sale:499.99,effective:499.99});
});
