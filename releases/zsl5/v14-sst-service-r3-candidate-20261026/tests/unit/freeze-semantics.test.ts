import test from 'node:test';import assert from 'node:assert/strict';
import {divRound,dollarsToCents,mulCentsByRate} from '../../apps/zsl-tax-intelligence/src/core/money.js';
import {boolRequirement,assertIsoInstant} from '../../apps/zsl-tax-intelligence/src/zsl5/runtime-semantics.js';
test('final freeze supports deterministic rounding modes',()=>{assert.equal(divRound(5n,2n,'HALF_UP'),3n);assert.equal(divRound(5n,2n,'HALF_EVEN'),2n);assert.equal(divRound(3n,2n,'HALF_EVEN'),2n);assert.equal(divRound(-5n,2n,'CEILING'),-2n);assert.equal(divRound(-5n,2n,'FLOOR'),-3n);assert.equal(mulCentsByRate(10000n,'0.053','HALF_UP'),530n);assert.equal(dollarsToCents('10.005','HALF_UP'),1001n)});
test('canonical seller collection enums fail closed',()=>{assert.equal(boolRequirement('REQUIRED','X'),true);assert.equal(boolRequirement('NOT_REQUIRED','X'),false);assert.throws(()=>boolRequirement('UNKNOWN','X'))});
test('quote instants require timezone',()=>{assert.doesNotThrow(()=>assertIsoInstant('2026-10-26T12:00:00Z','X'));assert.throws(()=>assertIsoInstant('2026-10-26T12:00:00','X'))});
