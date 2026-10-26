import test from 'node:test';import assert from 'node:assert/strict';import {mulCentsByRate,allocateProRata,parseDecimalToScale} from '../../apps/zsl-tax-intelligence/src/core/money.js';
test('decimal rate exact and half-up cents',()=>{assert.equal(mulCentsByRate(10000n,'0.053'),530n);assert.equal(mulCentsByRate(1n,'0.5'),1n);assert.equal(parseDecimalToScale('0.0825',10),825000000n)});
test('pro rata allocation preserves total deterministically',()=>{const a=allocateProRata(100n,[1n,1n,1n]);assert.deepEqual(a,[34n,33n,33n]);assert.equal(a.reduce((x,y)=>x+y,0n),100n)});
