import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import type {PoolClient} from 'pg';
import type {PolicyBundle} from '../../src/core/types.js';
import {canonicalLocationKey} from '../../src/normalizers/geography.js';
import {auditSourceGeography} from '../../src/normalizers/geography-preflight.js';
import {reconcileAcsGeography} from '../../src/certification/acs-geography-reconciliation.js';

const sourcePolicy=JSON.parse(fs.readFileSync('config/source-policy.json','utf8'));
const release='20a38d4d-d113-4736-af72-140ddb4eb860';
const binding={source_binding_id:'binding',source_key:'CENSUS_ACS5_PROFILE',source_dataset:'ACS',
  source_geography:'PLACE',source_vintage:'2024',release_id:release,ingest_run_id:'ingest'};
const exception=sourcePolicy.geographyExclusions[0];
const policy={source:sourcePolicy,feature:{acsVariableBindings:[{featureCode:'a'},{featureCode:'b'},{featureCode:'c'},{featureCode:'d'}]}} as PolicyBundle;

test('policy pins seven same-ANSI crosswalks and nineteen exact exclusions',()=>{
  assert.equal(sourcePolicy.geographyCrosswalks.length,7);
  assert.equal(sourcePolicy.geographyExclusions.length,19);
  assert.equal(new Set(sourcePolicy.geographyCrosswalks.map((x:any)=>x.sourceGEOID)).size,7);
  assert.equal(new Set(sourcePolicy.geographyExclusions.map((x:any)=>x.sourceGEOID)).size,19);
  assert.equal(canonicalLocationKey('PLACE',{state:'22',place:'26746'},
    {sourceKey:'CENSUS_ACS5_PROFILE',sourceVintage:'2024'},sourcePolicy.geographyCrosswalks),
    'US:PLACE:2226674');
  assert.equal(canonicalLocationKey('PLACE',{state:'22',place:'26746'},
    {sourceKey:'CENSUS_ACS5_PROFILE',sourceVintage:'2025'},sourcePolicy.geographyCrosswalks),
    'US:PLACE:2226746');
  assert.match(fs.readFileSync('database/migrations/012_zsl3_acs_geography_reconciliation_check.sql','utf8'),
    /'acs_geography_reconciled'/);
});

function preflightClient(includeUnknown=false):PoolClient {
  return {async query(sql:string){
    if(sql.includes('SELECT canonical_key'))return {rows:[
      {canonical_key:'US:PLACE:2226674'},
      ...sourcePolicy.geographyCrosswalks.map((x:any)=>({canonical_key:x.targetCanonicalKey})),
      {canonical_key:'US:PLACE:0100100'}]};
    if(sql.includes('FROM zsl.zsl3_source_bindings'))return {rows:[binding]};
    if(sql.includes('FROM zsl.release_record_memberships'))return {rows:[
      {record_id:'mapped',record:{state:'01',place:'00100'},record_sha256:'a'.repeat(64)},
      {record_id:'excluded',record:{state:'06',place:'81312'},record_sha256:'b'.repeat(64)},
      ...(includeUnknown?[{record_id:'unknown',record:{state:'99',place:'99999'},record_sha256:'c'.repeat(64)}]:[])]};
    throw Error(`unexpected query: ${sql}`);
  }} as unknown as PoolClient;
}

test('preflight rejects the whole unexpected set before fact writes',async()=>{
  const one={...policy,source:{...sourcePolicy,geographyExclusions:[exception],geographyExclusionRules:[]}} as PolicyBundle;
  const result=await auditSourceGeography(preflightClient(), 'build', one);
  assert.equal(result.checked,2);
  assert.equal(result.matched,1);
  assert.equal(result.exclusionsByRecordId.get('excluded')?.sourceGEOID,'0681312');
  await assert.rejects(auditSourceGeography(preflightClient(true),'build',one),/ZSL3_GEOGRAPHY_PREFLIGHT_FAILED/);
});

test('preflight rejects stale exception policy and missing certified crosswalk targets',async()=>{
  const stale={...policy,source:{...sourcePolicy,geographyExclusions:[exception,
    sourcePolicy.geographyExclusions[1]]}} as PolicyBundle;
  await assert.rejects(auditSourceGeography(preflightClient(),'build',stale),/ZSL3_GEOGRAPHY_PREFLIGHT_FAILED/);
  const missingTarget={...policy,source:{...sourcePolicy,geographyCrosswalks:[
    {...sourcePolicy.geographyCrosswalks[0],targetCanonicalKey:'US:PLACE:9999999'}],
    geographyExclusions:[exception]}} as PolicyBundle;
  await assert.rejects(auditSourceGeography(preflightClient(),'build',missingTarget),
    /ZSL3_CROSSWALK_TARGET_NOT_CERTIFIED/);
});

function reconciliationClient(tamper=false):PoolClient {
  return {async query(sql:string){
    if(sql.includes('FROM zsl.zsl3_source_bindings'))return {rows:[binding]};
    if(sql.includes('FROM zsl.release_record_memberships'))return {rows:[
      {record_id:'mapped',record_sha256:'a'.repeat(64)},
      {record_id:'excluded',record_sha256:'b'.repeat(64)}]};
    if(sql.includes('FROM zsl.zsl3_source_facts'))return {rows:[{source_record_id:'mapped',facts:tamper?'3':'4'}]};
    if(sql.includes('FROM zsl.zsl3_conflicts'))return {rows:[{evidence:{
      sourceBindingId:'binding',sourceReleaseId:release,sourceRecordId:'excluded',sourceRecordSha256:'b'.repeat(64),
      sourceVintage:'2024',sourceGEOID:'0681312',authorityCode:exception.authorityCode,
      reasonCode:'NO_CURRENT_ANSI_SUCCESSOR',geographyEvidence:sourcePolicy.geographyEvidence
    }}]};
    throw Error(`unexpected query: ${sql}`);
  }} as unknown as PoolClient;
}

test('certification reconciles each raw ACS record to complete facts or one approved warning',async()=>{
  const one={...policy,source:{...sourcePolicy,geographyExclusions:[exception]}} as PolicyBundle;
  const good=await reconcileAcsGeography(reconciliationClient(),'build',one);
  assert.equal(good.ok,true);
  assert.deepEqual([good.checked,good.matched,good.excluded,good.missing,good.partial],[2,1,1,0,0]);
  const bad=await reconcileAcsGeography(reconciliationClient(true),'build',one);
  assert.equal(bad.ok,false);
  assert.equal(bad.partial,1);
});
