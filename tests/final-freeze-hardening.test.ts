import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('BEA RPP CLI requires metadata-verified table and line code with no unverified default', async()=>{
  const s=await readFile('src/cli/ingest.ts','utf8');
  assert.equal(s.includes('RPPALL'),false);
  assert.match(s,/metadata-verified-tableName/);
  assert.match(s,/bea-rpp-state <year>/);
  assert.match(s,/bea-rpp-msa <year>/);
});

test('raw record membership loading is set-based within batches', async()=>{
  const s=await readFile('src/repositories/ingest.repository.ts','utf8');
  assert.match(s,/record_sha256=ANY\(\$1::text\[\]\)/);
  assert.match(s,/INSERT INTO zsl\.release_record_memberships[\s\S]*VALUES \$\{mv\.join\(','\)\}/);
  assert.equal(s.includes('SELECT record_id::text FROM zsl_raw.raw_records WHERE record_sha256=$1'),false);
});

test('V2.1 has a non-destructive rollback preserving evidence', async()=>{
  const s=await readFile('database/rollback/002_zsl1_v21_non_destructive_rollback.sql','utf8');
  assert.match(s,/retain/i);
  assert.match(s,/DROP VIEW IF EXISTS zsl\.certified_release_records/);
  assert.equal(/DROP TABLE/i.test(s),false);
});
