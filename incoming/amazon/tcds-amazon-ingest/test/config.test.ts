import test from 'node:test';
import assert from 'node:assert/strict';
import {
  parseAmazonKeywords,
  parseAmazonZipcode
} from '../src/config.js';

test('normalizes and deduplicates Amazon keywords', () => {
  assert.deepEqual(
    parseAmazonKeywords('iphone, laptop,iphone'),
    ['iphone', 'laptop']
  );
});

test('validates optional Amazon ZIP code', () => {
  assert.equal(parseAmazonZipcode(' 10001 '), '10001');
  assert.equal(parseAmazonZipcode(''), '');
  assert.throws(() => parseAmazonZipcode('invalid'));
});
