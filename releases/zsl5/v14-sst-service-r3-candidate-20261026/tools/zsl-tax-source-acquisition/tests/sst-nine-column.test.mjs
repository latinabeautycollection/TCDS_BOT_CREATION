import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {parse} from 'csv-parse/sync';
import {sstRateAdapter as adapter} from '../adapters/sst/rate.ts';
import {validateRecords} from '../normalization/schema-validator.ts';
import {bindAndLoadNationalPublication} from '../../../apps/zsl-tax-intelligence/src/zsl5/national-loader.ts';
const hash=b=>createHash('sha256').update(b).digest('hex');
const ctx=b=>({sourceKey:'sst_rate_boundary',releaseId:'00000000-0000-4000-8000-000000000001',
 artifactSha256:hash(b),authorityRank:1,retrievedAt:'2026-10-25T18:18:33.632082+00:00',
 parserVersion:adapter.adapterKey,normalizationVersion:'test'});
const filename='GAR2026Q4OCT01.csv';
const synthetic=Buffer.from('13,45,13,.04,.04,0,0,20110101,29991231\n');
const run=(bytes,name=filename)=>adapter.parse(bytes,ctx(bytes),name);
test('real Georgia source: 460 rows, one state and 459 local observations',async()=>{
 const bytes=await readFile(process.env.TCDS_GA_CSV);
 assert.equal(hash(bytes),'36f6d0c170c53819766496690942cd96e1a0c02060301fbf88e2871b95b45171');
 const source=parse(bytes,{bom:true,skip_empty_lines:true,trim:true});
 const records=await run(bytes);
 assert.equal(records.length,460);
 assert.equal(records.filter(x=>x.record_type==='STATE_RATE').length,1);
 assert.equal(records.filter(x=>x.record_type==='LOCAL_RATE').length,459);
 for(let i=0;i<records.length;i++){
  const p=records[i].payload,s=source[i];
  assert.deepEqual(Object.values(p.rates),s.slice(3,7).map(v=>v===''?null:v));
  assert.equal(p.jurisdiction_type_code_raw,s[1]);
  assert.equal(p.jurisdiction_code,s[2]);
  assert.equal(p.source_effective_from.replaceAll('-',''),s[7]);
  assert.equal(p.source_effective_to.replaceAll('-',''),s[8]);
  assert.equal(p.executable,false); assert.equal('rate' in p,false);
  assert.equal(records[i].effective_to,null);
 }
 assert.deepEqual(await run(bytes),records);
 const validation=await validateRecords(records);
 assert.equal(validation.status,'PASS',JSON.stringify(validation.failures.slice(0,2)));
 assert.equal(validation.checked_count,460);
});
test('all four variants remain distinct',async()=>{
 const [r]=await run(Buffer.from('13,45,13,.04,.03,.02,.01,20260101,20261231\n'));
 assert.deepEqual(Object.values(r.payload.rates),['.04','.03','.02','.01']);
});
test('missing food rates remain null, not zero',async()=>{
 const [r]=await run(Buffer.from('13,45,13,.04,.04,,,20260101,20261231\n'));
 assert.equal(r.payload.rates.food_drug_intrastate,null);
 assert.equal(r.payload.rates.food_drug_interstate,null);
});
test('empty file fails closed',async()=>assert.rejects(run(Buffer.alloc(0)),/SST_EMPTY_ARTIFACT/));
test('hash mismatch rejected',async()=>assert.rejects(adapter.parse(synthetic,{...ctx(synthetic),artifactSha256:'0'.repeat(64)},filename),/HASH_MISMATCH/));
test('unbound source rejected',async()=>assert.rejects(adapter.parse(synthetic,{...ctx(synthetic),releaseId:'UNBOUND_RELEASE'},filename),/BOUND_RELEASE/));
test('unsupported file format rejected',async()=>assert.rejects(run(synthetic,'Georgia.xlsx'),/UNSUPPORTED_FORMAT/));
test('wrong state rejected',async()=>assert.rejects(run(Buffer.from('12,45,12,.04,.04,0,0,20260101,20261231\n')),/STATE_MISMATCH/));
test('wrong column count rejected',async()=>assert.rejects(run(Buffer.from('13,45,13,.04\n')),/NINE_COLUMNS/));
test('invalid calendar date rejected',async()=>assert.rejects(run(Buffer.from('13,45,13,.04,.04,0,0,20260230,20261231\n')),/INVALID_DATE/));
test('reversed source dates rejected',async()=>assert.rejects(run(Buffer.from('13,45,13,.04,.04,0,0,20261231,20260101\n')),/REVERSED/));
test('invalid rate rejected',async()=>assert.rejects(run(Buffer.from('13,45,13,1.1,.04,0,0,20260101,20261231\n')),/INVALID_RATE/));
test('duplicate source identities rejected',async()=>assert.rejects(run(Buffer.concat([synthetic,synthetic])),/DUPLICATE/));
test('empty schema validation cannot pass',async()=>assert.rejects(validateRecords([]),/EMPTY_CANONICAL/));
test('malformed observation schema rejected',async()=>{
 const records=await run(synthetic); delete records[0].payload.rates;
 assert.equal((await validateRecords(records)).status,'FAIL');
});
test('existing scalar schema remains supported',async()=>{
 const [r]=await run(synthetic);
 r.payload={jurisdiction_code:'13',component_code:'STATE',component_type:'STATE',rate:0.04,rate_semantics:'COMPONENT'};
 assert.equal((await validateRecords([r])).status,'PASS');
});
test('acquisition and runtime rate schemas are identical',async()=>{
 for(const name of ['state-rate','local-rate']){
  const acquisition=JSON.parse(await readFile(new URL('../schemas/'+name+'.schema.json',import.meta.url),'utf8'));
  const runtime=JSON.parse(await readFile(new URL('../../../apps/zsl-tax-intelligence/schemas/'+name+'.schema.json',import.meta.url),'utf8'));
  assert.deepEqual(acquisition,runtime);
 }
});
test('real loader refuses observation publication before any write (mock database)',async()=>{
 const calls=[];
 const c={async query(sql){calls.push(sql);
  if(sql.includes('pg_advisory'))return {rows:[],rowCount:1};
  if(sql.includes('from zsl.zsl5_build_runs'))return {rows:[{build_run_id:'test'}],rowCount:1};
  if(sql.includes('from zsl_tax_acq.national_publication_runs'))return {rows:[{publication_id:'test'}],rowCount:1};
  if(sql.includes('SST_NINE_COLUMN_RATE_OBSERVATION_V1'))return {rows:[{}],rowCount:1};
  throw new Error('Unexpected query');}};
 await assert.rejects(bindAndLoadNationalPublication(c,'test','test','isolated-test'),/REQUIRE_APPROVED_EXECUTABLE_MAPPING/);
 assert.equal(calls.some(s=>/\b(insert|update|delete)\b/i.test(s)),false);
});
