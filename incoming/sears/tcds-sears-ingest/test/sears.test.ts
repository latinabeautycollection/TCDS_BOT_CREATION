import assert from 'node:assert/strict';
import test from 'node:test';
import {
  canonicalSearsProductUrl,
  extractLocations,
  evenlySample
} from '../src/discovery.js';
import { parseSearsPdp } from '../src/parser.js';

test('extracts and canonicalizes first-party Sears PDP URLs', () => {
  const xml = `
    <urlset>
      <url><loc>https://www.sears.com/tool-name/p-A123?sid=test</loc></url>
      <url><loc>https://example.com/tool-name/p-A999</loc></url>
    </urlset>
  `;
  const locations = extractLocations(xml);
  assert.equal(
    canonicalSearsProductUrl(locations[0]!),
    'https://www.sears.com/tool-name/p-A123'
  );
  assert.equal(canonicalSearsProductUrl(locations[1]!), null);
});

test('samples candidates across the full sitemap instead of its stale prefix', () => {
  assert.deepEqual(evenlySample([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], 4), [0, 3, 6, 9]);
});

test('parses rendered Sears PDP fields and ignores savings amounts', () => {
  const html = `
    <link rel="canonical" href="https://www.sears.com/craftsman-tool/p-A028691138">
    <div id="pdp-main-image"><img alt="Craftsman Tool" src="https://c.shld.net/main.jpg"></div>
    <h1 class="h2-ui-specs h2-new-ui">Craftsman Tool Set</h1>
    <p>Sold By <span class="bold">Sears</span></p>
    <del class="pricing-crossed-ui"><span>$69.99</span></del>
    <span class="pricing-sale-ui">$26.99 <span>Save - $43.00</span></span>
    <div id="description"><p class="handle-Short-description-tags">Useful tool set.</p></div>
    <div id="specifications">
      Item# : 00947017000
      Model # : 70970
      <div class="list-key">Brand:</div><div class="list-value">Craftsman</div>
    </div>
    Add to Cart
  `;
  const parsed = parseSearsPdp(
    html,
    'https://www.sears.com/craftsman-tool/p-A028691138'
  );
  assert.equal(parsed.item_id, 'A028691138');
  assert.equal(parsed.title, 'Craftsman Tool Set');
  assert.equal(parsed.price, '$69.99');
  assert.equal(parsed.sale_price, '$26.99');
  assert.equal(parsed.mpn, '70970');
  assert.equal(parsed.brand, 'Craftsman');
  assert.equal(parsed.availability, 'in_stock');
  assert.equal(parsed.image_url, 'https://c.shld.net/main.jpg');
});
