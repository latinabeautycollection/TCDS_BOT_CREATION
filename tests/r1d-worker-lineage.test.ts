import test from 'node:test';
import assert from 'node:assert/strict';
import {
  extractWorkerMetrics,
  requireCertificationCollectionRunId
} from '../scripts/retail-automation/r1d/worker-lineage';

const runId='e64b5888-d77b-4aa4-b10d-2e32caaad5ea';

test('extracts an explicit R1D metric envelope',()=>{
  const metrics=extractWorkerMetrics(
    JSON.stringify({r1d_metrics:{collection_run_id:runId,records_collected:3}})
  );
  assert.equal(metrics.collection_run_id,runId);
  assert.equal(metrics.records_collected,3);
});

test('adapts the certified Best Buy terminal event',()=>{
  const stdout=[
    JSON.stringify({event:'snapshot_poll',status:'ready'}),
    JSON.stringify({
      event:'worker_complete',run_id:runId,total_rows:10,
      collected:9,failed:1
    })
  ].join('\n');
  assert.deepEqual(extractWorkerMetrics(stdout),{
    collection_run_id:runId,
    records_requested:10,
    records_collected:9,
    records_failed:1
  });
});

test('adapts the certified Target Pino terminal event',()=>{
  const stdout=[
    JSON.stringify({
      level:30,
      snapshot:'sd_test',
      records:100,
      msg:'Target snapshot downloaded'
    }),
    JSON.stringify({
      level:30,
      runId,
      collected:82,
      failed:17,
      skipped:1,
      recovered:17,
      msg:'Target ingest completed'
    })
  ].join('\n');

  assert.deepEqual(extractWorkerMetrics(stdout),{
    collection_run_id:runId,
    records_requested:100,
    records_collected:82,
    records_failed:17,
    records_skipped:1,
    records_recovered:17
  });
});

test('certification lineage rejects absent and malformed run IDs',()=>{
  assert.throws(
    ()=>requireCertificationCollectionRunId({}),
    /valid collection_run_id/
  );
  assert.throws(
    ()=>requireCertificationCollectionRunId({collection_run_id:'not-a-uuid'}),
    /valid collection_run_id/
  );
  assert.equal(
    requireCertificationCollectionRunId({collection_run_id:runId}),
    runId
  );
});
