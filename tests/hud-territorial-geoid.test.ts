import assert from 'node:assert/strict';
import test from 'node:test';
import { HudUspsAdapter } from '../src/adapters/hud-usps.adapter.js';

const record = (state: string, geoid: string) => ({
  naturalKey: `96799:${geoid}`,
  record: {
    zip: '96799',
    geoid,
    state,
    res_ratio: 0,
    bus_ratio: 0,
    oth_ratio: 1,
    tot_ratio: 1
  }
});

test('accepts exact HUD territorial county-code pairs', () => {
  const adapter = new HudUspsAdapter(2, 2025, 4);

  for (const [state, geoid] of [
    ['AS', '60'],
    ['FM', '64'],
    ['MH', '68'],
    ['PW', '70']
  ] as const) {
    assert.equal(adapter.validateRecord(record(state, geoid)).valid, true);
  }
});

test('rejects mismatched territorial county codes', () => {
  const adapter = new HudUspsAdapter(2, 2025, 4);
  assert.equal(adapter.validateRecord(record('AS', '64')).valid, false);
});

test('CBSA still requires a five-digit GEOID', () => {
  const adapter = new HudUspsAdapter(3, 2025, 4);
  assert.equal(adapter.validateRecord(record('AS', '60')).valid, false);
  assert.equal(adapter.validateRecord(record('NY', '35620')).valid, true);
});
