import assert from 'node:assert/strict';
import test from 'node:test';
import { assertRatioDecimal, normalizeDecimal } from '../src/core/exact.js';

test('normalizeDecimal rounds to scale without floating-point arithmetic', () => {
  assert.equal(normalizeDecimal('0.9952603515', 'ratio', 9), '0.995260352');
  assert.equal(normalizeDecimal('0.9952603514', 'ratio', 9), '0.995260351');
  assert.equal(normalizeDecimal('-0.0000000005', 'value', 9), '-0.000000001');
  assert.equal(normalizeDecimal('1.9999999995', 'value', 9), '2.000000000');
});

test('ratio validation runs on the rounded scale-9 value', () => {
  assert.equal(assertRatioDecimal('0.9952603515', 'ratio', 9), '0.995260352');
  assert.throws(
    () => assertRatioDecimal('1.0000000005', 'ratio', 9),
    /INVALID_HUD_RATIO/
  );
});
