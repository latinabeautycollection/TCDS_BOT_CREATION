import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

test('runtime activation requires authority gate',async()=>{
 const s=await readFile('database/migrations/045a_zsl5_v14_runtime_certification.sql','utf8');
 assert.match(s,/zsl5_v14_runtime_ready/);assert.match(s,/RUNTIME_AUTHORITY_GATE_NOT_PASS/);
});

test('candidate quote execution is a separate export and public quote remains active-only',async()=>{
 const s=await readFile('apps/zsl-tax-intelligence/src/zsl5/tax-quote-v14.service.ts','utf8');
 assert.match(s,/export async function quoteTaxV14\(/);
 assert.match(s,/export async function quoteTaxV14Candidate\(/);
 assert.match(s,/mode:'ACTIVE'\|'CERTIFICATION'/);
 assert.match(s,/ZSL5_V14_BUILD_NOT_ACTIVE/);
});

test('golden and replay runners do not invent wall-clock evaluation times',async()=>{
 for(const f of ['run-national-tax-certification.ts','run-replay-certification.ts']){
  const s=await readFile('apps/zsl-tax-intelligence/src/runtime/'+f,'utf8');
  assert.equal(/new Date\(\)\.toISOString/.test(s),false);
  assert.match(s,/evaluationAsOf|evaluation_as_of/);
 }
});

test('freshness and ten-category gates are part of v14 authority',async()=>{
 const s=await readFile('database/migrations/046b_zsl5_v14_freshness_security_activation.sql','utf8');
 assert.match(s,/freshness_ready/);assert.match(s,/mapped_category_count/);assert.match(s,/=10/);
});
