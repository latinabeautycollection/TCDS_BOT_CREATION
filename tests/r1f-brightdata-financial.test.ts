import assert from 'node:assert/strict';
import test from 'node:test';
import {
  parseBrightDataCostBreakdown,
  parseBrightDataZoneCost
} from '../scripts/retail-automation/r1f/brightdata-financial.ts';

test('accepts dynamic /zone/cost account keys',()=>{
  const rows=parseBrightDataZoneCost({
    hl_ae30ad2f:{
      custom:{cost:0.155,bw:183453595,reqs_premium_unblocker:62}
    }
  });
  assert.deepEqual(rows,[{
    accountKey:'hl_ae30ad2f',
    bucketKey:'custom',
    billedCostUsd:'0.155',
    bandwidthBytes:'183453595',
    raw:{cost:0.155,bw:183453595,reqs_premium_unblocker:62}
  }]);
});

test('accepts legacy ID /zone/cost payloads',()=>{
  const rows=parseBrightDataZoneCost({ID:{back_d0:{cost:0,bw:0}}});
  assert.equal(rows[0].accountKey,'ID');
  assert.equal(rows[0].bucketKey,'back_d0');
});

test('excludes total from daily rows and verifies exact resource sums',()=>{
  const rows=parseBrightDataCostBreakdown({
    '2026-09-16':{gd_target:0.003,gd_other:0.006},
    '2026-09-20':{gd_target:1.236},
    total:{gd_target:1.239,gd_other:0.006}
  },'2026-09-16','2026-09-21');
  assert.equal(rows.length,3);
  assert.equal(rows.some(row=>row.costDay==='total'),false);
});

test('rejects a provider total that differs from daily entries',()=>{
  assert.throws(()=>parseBrightDataCostBreakdown({
    '2026-09-20':{gd_target:1.236},
    total:{gd_target:1.235}
  },'2026-09-20','2026-09-21'),/total mismatch/);
});
