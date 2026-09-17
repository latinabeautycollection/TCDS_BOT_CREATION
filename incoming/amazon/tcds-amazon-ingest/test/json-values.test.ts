import test from 'node:test';
import assert from 'node:assert/strict';
import { pgJson } from '../src/db.js';

test('serializes string-valued JSON columns', () => {
  assert.equal(pgJson('20% off'), '"20% off"');
  assert.equal(pgJson(null), 'null');
  assert.equal(pgJson({ amount: 20 }), '{"amount":20}');
});
