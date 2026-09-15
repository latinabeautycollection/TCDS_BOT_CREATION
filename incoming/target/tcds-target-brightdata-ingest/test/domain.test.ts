import test from 'node:test';import assert from 'node:assert/strict';import {targetRecordSchema,normalizeTarget} from '../src/domain.js';import {parseTargetJsonLd} from '../src/unlocker.js';
test('normalizes Target record',()=>{const p=targetRecordSchema.parse({url:'https://www.target.com/p/x/-/A-1',product_id:'1',title:'X',final_price:12.5,currency:'USD',is_available:true,images:[],breadcrumbs:[],product_specifications:[],shipping_returns_policy:[],related_categories:[],amount_of_stars:[],recommendations:[],variations:[],what_customers_said:[],review_images:[],product_variant:[],customer_reviews:[],variant_attributes:[],variants:[],category_urls:[],target_countries:[]});assert.equal(normalizeTarget(p).effective,12.5);});
test('extracts Product JSON-LD',()=>{const h='<script type="application/ld+json">{"@type":"Product","name":"Laptop"}</script>';assert.equal(parseTargetJsonLd(h)?.name,'Laptop');});
test('preserves unknown availability',()=>{const p=targetRecordSchema.parse({url:'https://www.target.com/p/x/-/A-2',product_id:'2',title:'X',final_price:12.5,currency:'USD',images:[],breadcrumbs:[],product_specifications:[],shipping_returns_policy:[],related_categories:[],amount_of_stars:[],recommendations:[],variations:[],what_customers_said:[],review_images:[],product_variant:[],customer_reviews:[],variant_attributes:[],variants:[],category_urls:[],target_countries:[]});const n=normalizeTarget(p);assert.equal(n.availability,'unknown');assert.equal(n.available,null);});

test('accepts nullable Target array fields',()=>{const p=targetRecordSchema.parse({url:'https://www.target.com/p/x/-/A-3',product_id:'3',title:'X',final_price:10,product_variant:null,variant_attributes:null,variants:null,category_urls:null});assert.deepEqual(p.product_variant,[]);assert.deepEqual(p.variant_attributes,[]);assert.deepEqual(p.variants,[]);assert.deepEqual(p.category_urls,[]);});

import { buildTargetDiscoveryInput } from '../src/config.js';

test('broadcasts one Target ZIP across all keywords', () => {
  const result = buildTargetDiscoveryInput(
    'iphone,laptop',
    '10001'
  );

  assert.deepEqual(result.input, [
    { keywords: 'iphone', zipcode: '10001' },
    { keywords: 'laptop', zipcode: '10001' }
  ]);
});

test('pairs Target ZIP codes positionally', () => {
  const result = buildTargetDiscoveryInput(
    'iphone,laptop',
    '10001,90210'
  );

  assert.deepEqual(result.input, [
    { keywords: 'iphone', zipcode: '10001' },
    { keywords: 'laptop', zipcode: '90210' }
  ]);
});

test('rejects ambiguous Target ZIP mappings', () => {
  assert.throws(
    () => buildTargetDiscoveryInput(
      'iphone,laptop,tablet',
      '10001,90210'
    ),
    /one ZIP per keyword/
  );
});
