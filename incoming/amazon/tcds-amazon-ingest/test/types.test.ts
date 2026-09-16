import test from 'node:test';
import assert from 'node:assert/strict';
import { AmazonRecordSchema } from '../src/types.js';

const baseRecord = {
  title: 'Apple iPhone 15 Pro',
  asin: 'B0CTEST123',
  url: 'https://www.amazon.com/dp/B0CTEST123'
};

test('preserves textual product descriptions', () => {
  const result = AmazonRecordSchema.parse({
    ...baseRecord,
    product_description: 'Phone description'
  });

  assert.equal(result.product_description, 'Phone description');
});

test('drops media arrays supplied as product descriptions', () => {
  const result = AmazonRecordSchema.parse({
    ...baseRecord,
    product_description: [
      { type: 'image', url: 'https://example.com/a.jpg' }
    ]
  });

  assert.equal(result.product_description, null);
});
