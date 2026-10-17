import test from 'node:test';
import assert from 'node:assert/strict';
import type {PoolClient} from 'pg';
import type {PolicyBundle} from '../../src/core/types.js';
import {reconcileBusinessGeography} from '../../src/certification/business-geography-reconciliation.js';

const rule={sourceKey:'CENSUS_CBP',sourceVintage:'2023',sourceReleaseId:'release',geography:'COUNTY' as const,
  field:'county' as const,value:'999',expectedCount:1,reasonCode:'NON_COUNTY_AGGREGATE'};
const policy={source:{geographyExclusionRules:[rule]}} as PolicyBundle;
const binding={source_binding_id:'binding',source_key:'CENSUS_CBP',source_dataset:'CBP',source_vintage:'2023',
  source_geography:'COUNTY',release_id:'release',ingest_run_id:'ingest'};

function client(warning=true,fact=false):PoolClient{
  return {async query(sql:string){
    if(sql.includes('FROM zsl.zsl3_source_bindings'))return {rows:[binding]};
    if(sql.includes('FROM zsl.zsl3_conflicts'))return {rows:warning?[{evidence:{sourceBindingId:'binding',sourceReleaseId:'release',
      sourceRecordId:'record',sourceRecordSha256:'a'.repeat(64),sourceVintage:'2023',sourceKey:'CENSUS_CBP',
      geography:'COUNTY',field:'county',value:'999',reasonCode:'NON_COUNTY_AGGREGATE'}}]:[]};
    if(sql.includes('FROM zsl.certified_release_records'))return {rows:[{record_id:'record',record_sha256:'a'.repeat(64),record:{county:'999'}}]};
    if(sql.includes('FROM zsl.zsl3_source_facts'))return {rows:fact?[{one:1}]:[]};
    throw Error(`unexpected query: ${sql}`);
  }} as unknown as PoolClient;
}

test('business exceptions require source-matched warning and zero location facts',async()=>{
  assert.equal((await reconcileBusinessGeography(client(), 'run',policy)).ok,true);
  assert.equal((await reconcileBusinessGeography(client(false), 'run',policy)).ok,false);
  assert.equal((await reconcileBusinessGeography(client(true,true), 'run',policy)).ok,false);
});
