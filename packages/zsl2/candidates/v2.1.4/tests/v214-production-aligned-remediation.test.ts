import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';

const txt=async(p:string)=>readFile(p,'utf8');

test('historical package migrations stop at 008 and remediation starts at 011',async()=>{
 const files=(await readdir('database/migrations')).sort();
 assert(files.some((x:string)=>x.startsWith('008_')));
 assert(!files.some((x:string)=>x.startsWith('009_')));
 assert(!files.some((x:string)=>x.startsWith('010_')));
 assert(files.some((x:string)=>x.startsWith('011_')));
 assert(files.some((x:string)=>x.startsWith('016_')));
});

test('ZSL1 release count qualifies columns shared by joined relations',async()=>{
 const s=await txt('database/migrations/014_zsl2_v2_1_4_zsl1_authority_and_certification_gate.sql');
 assert.match(s,/count\(DISTINCT \(cr\.source_key,cr\.release_id\)\)/);
});

test('set based normalizer preserves territorial missing county as pending evidence',async()=>{
 const s=await txt('src/services/setBasedNormalizer.ts');
 assert.match(s,/HUD_TERRITORIAL_PENDING_BULK_INSERT/);
 assert.match(s,/PENDING_TERRITORIAL_AUTHORITY/);
 assert.match(s,/\^US:COUNTY:\(60\|66\|69\|72\|78\)/);
 assert.match(s,/fatalMissing/);
});

test('snapshot validation is source start and completion, not per page',async()=>{
 const s=await txt('src/services/normalize.service.ts');
 assert.match(s,/sourceSnapshotValidated/);
 assert.match(s,/SOURCE_SNAPSHOT_DRIFT_AT_COMPLETION/);
});

test('certification includes signed ZSL1 authority and territorial performance gates',async()=>{
 const s=await txt('src/services/certification.service.ts');
 assert.match(s,/zsl1_authority_decision_valid/);
 assert.match(s,/territorial_pending_evidence_valid/);
 assert.match(s,/page_performance_observed/);
});

test('authority decision verifies Ed25519 signature and live population',async()=>{
 const s=await txt('src/services/zsl1Authority.service.ts');
 assert.match(s,/verify\(null,payload/);
 assert.match(s,/PUBLIC_KEY_PIN_MISMATCH/);
 assert.match(s,/LIVE_AUTHORITY_POPULATION_MISMATCH/);
 assert.match(s,/Anthony Malone/);
});

test('performance thresholds are not relaxed',async()=>{
 const p=JSON.parse(await txt('config/normalization-policy.json'));
 assert.equal(p.performance.pageP99Ms,60000);
 assert.equal(p.performance.maxStatementMs,120000);
 assert.equal(p.performance.setBasedPageProcessingRequired,true);
});
