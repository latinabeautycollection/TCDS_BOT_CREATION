import test from 'node:test';
import assert from 'node:assert/strict';
import { uniqueRunKey } from '../src/util.js';

test('creates unique auditable run keys for identical scope', () => {
  const first = uniqueRunKey('amazon', 'iphone|10001');
  const second = uniqueRunKey('amazon', 'iphone|10001');

  assert.notEqual(first, second);
  assert.match(first, /^amazon:\d{4}-\d{2}-\d{2}T.*:[0-9a-f]{12}:[0-9a-f-]{36}$/);
});
