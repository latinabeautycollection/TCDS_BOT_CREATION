import assert from 'node:assert/strict';
import test from 'node:test';
import { providerError } from '../src/provider.js';
import { HARBORFREIGHTRecordSchema } from '../src/types.js';

test('accepts nullable Bright Data array fields', () => {
  const parsed = HARBORFREIGHTRecordSchema.parse({
    url: 'https://www.harborfreight.com/example-12345.html',
    item_id: 12345,
    title: 'Example tool',
    category_tree: null,
    additional_image_urls: null,
    additional_video_urls: null,
    variant_attributes: null,
    variants: null,
    target_countries: null,
    category_urls: null,
    reviews: null
  });

  assert.deepEqual(parsed.category_tree, []);
  assert.deepEqual(parsed.additional_image_urls, []);
  assert.deepEqual(parsed.variants, []);
});

test('classifies provider errors before record validation', () => {
  assert.deepEqual(
    providerError({ error_code: 'crawl_error', error: 'Crawler failed' }),
    { code: 'PROVIDER_crawl_error', message: 'Crawler failed' }
  );
  assert.equal(providerError({ item_id: '12345' }), null);
});
