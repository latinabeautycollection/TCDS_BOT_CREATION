import assert from 'node:assert/strict';
import test from 'node:test';
import { discoverCostcoInputs, extractCostcoPdpOffer, extractCostcoProductUrls } from '../src/discovery.js';
import { CostcoRecordSchema } from '../src/types.js';
import { normalizePrices } from '../src/util.js';

test('extracts canonical unique Costco PDP URLs',()=>{const html=`<a href="/one.product.4001.html?x=1">one</a><a href="https://www.costco.com/one.product.4001.html">duplicate</a><a href="/laptops.html">category</a><a href="https://evil.example/x.product.9.html">bad</a>`;assert.deepEqual(extractCostcoProductUrls(html,'https://www.costco.com/laptops.html'),['https://www.costco.com/one.product.4001.html']);});

test('discovers products up to the global limit',async()=>{const inputs=await discoverCostcoInputs(['https://www.costco.com/a.html','https://www.costco.com/b.html'],async url=>url.endsWith('a.html')?'<a href="/one.product.1.html"></a><a href="/two.product.2.html"></a>':'<a href="/three.product.3.html"></a>',2);assert.equal(inputs.length,2);assert.equal(inputs[0]?.url,'https://www.costco.com/one.product.1.html');});

test('accepts nullable Bright Data array fields',()=>{const row=CostcoRecordSchema.parse({url:'https://www.costco.com/x.product.1.html',item_id:'1',title:'X',price:'10',category_tree:null,additional_image_urls:null,variant_attributes:null,variants:null,reviews:null,target_countries:null,category_urls:null});assert.deepEqual(row.category_tree,[]);assert.deepEqual(row.variants,[]);assert.deepEqual(row.category_urls,[]);});

test('normalizes Costco reversed price labels',()=>{assert.deepEqual(normalizePrices('$799.99','$1,099.99'),{regular:1099.99,sale:799.99,effective:799.99});assert.deepEqual(normalizePrices('$229.99',null),{regular:229.99,sale:null,effective:229.99});});

test('extracts a Costco PDP offer from Product JSON-LD',()=>{const html=`<script type="application/ld+json">{"@context":"https://schema.org","@type":"BreadcrumbList"}</script><script type="application/ld+json">{"@context":"https://schema.org","@type":"Product","offers":{"@type":"Offer","availability":"https://schema.org/InStock","priceCurrency":"USD","price":829.99}}</script>`;assert.deepEqual(extractCostcoPdpOffer(html),{price:829.99,currency:'USD',availability:'instock'});});

test('does not use unrelated JSON-LD prices',()=>{const html=`<script type="application/ld+json">{"@type":"AggregateOffer","price":1}</script>`;assert.equal(extractCostcoPdpOffer(html),null);});
