import test from 'node:test';import assert from 'node:assert/strict';
import {TCDS_TAX_CATEGORIES} from '../../apps/zsl-tax-intelligence/src/core/types.js';
test('ten TCDS tax categories',()=>{assert.equal(TCDS_TAX_CATEGORIES.length,10);assert.equal(new Set(TCDS_TAX_CATEGORIES).size,10);assert.ok(TCDS_TAX_CATEGORIES.includes('CAMERAS'));assert.ok(TCDS_TAX_CATEGORIES.includes('ELECTRONICS'));assert.ok(TCDS_TAX_CATEGORIES.includes('GAME_CONSOLES'));});
