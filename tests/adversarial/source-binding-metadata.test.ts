import test from 'node:test';
import assert from 'node:assert/strict';
import type {PoolClient} from 'pg';
import type {PolicyBundle, GeographyScope} from '../../src/core/types.js';
import {bindSources, expectedReleaseMetadata} from '../../src/bindings/source-binding.service.js';

test('certified release metadata uses exact source-specific identities', () => {
  for (const geography of ['STATE', 'COUNTY', 'PLACE', 'ZCTA'] as GeographyScope[]) {
    assert.deepEqual(expectedReleaseMetadata('CENSUS_ACS5_PROFILE', 'ACS', geography),
      {dataset: 'acs/acs5/profile', geography});
  }
  assert.deepEqual(expectedReleaseMetadata('BEA_REGIONAL_RPP', 'BEA_RPP', 'STATE'),
    {dataset: 'Regional', geoFips: 'STATE', tableName: 'SARPP', lineCode: '1'});
  assert.deepEqual(expectedReleaseMetadata('BEA_REGIONAL_RPP', 'BEA_RPP', 'MSA'),
    {dataset: 'Regional', geoFips: 'MSA', tableName: 'MARPP', lineCode: '1'});
  assert.deepEqual(expectedReleaseMetadata('CENSUS_CBP', 'CBP', 'COUNTY'),
    {dataset: 'CBP', geography: 'COUNTY'});
  assert.deepEqual(expectedReleaseMetadata('CENSUS_ZBP', 'ZBP', 'POSTAL_CODE'),
    {dataset: 'ZBP', geography: 'POSTAL_CODE'});
});

test('unsupported source, dataset, and geography combinations fail closed', () => {
  assert.throws(() => expectedReleaseMetadata('CENSUS_ACS5_PROFILE', 'CBP', 'STATE'),
    /ZSL3_UNSUPPORTED_SOURCE_METADATA/);
  assert.throws(() => expectedReleaseMetadata('BEA_REGIONAL_RPP', 'BEA_RPP', 'COUNTY'),
    /ZSL3_UNSUPPORTED_SOURCE_METADATA/);
  assert.throws(() => expectedReleaseMetadata('UNKNOWN', 'ACS', 'STATE'),
    /ZSL3_UNSUPPORTED_SOURCE_METADATA/);
});

test('binding queries exact certified metadata and persists the matched contract', async () => {
  const packageSha = '8565bda4f631f56e8f9aa1db6982144182a7076027cc77811e9398bc5a29a43c';
  const calls: Array<{sql: string; values: unknown[]}> = [];
  const client = {
    async query(sql: string, values: unknown[]) {
      calls.push({sql, values});
      if (calls.length === 1) {
        return {rows: [{
          source_key: 'BEA_REGIONAL_RPP', release_id: 'release', release_key: '2024:SARPP:STATE:1',
          source_year: 2024, source_quarter: null, ingest_run_id: 'ingest',
          certification_run_id: 'cert', package_sha256: packageSha
        }]};
      }
      return {rows: []};
    }
  } as unknown as PoolClient;
  const policy = {
    source: {requiredSources: [{sourceKey: 'BEA_REGIONAL_RPP', dataset: 'BEA_RPP',
      geographies: ['STATE'], required: true}]},
    upstream: {zsl1: {sha256BySourceKey: {BEA_REGIONAL_RPP: packageSha}}}
  } as unknown as PolicyBundle;

  assert.equal(await bindSources(client, 'build', policy), 1);
  assert.match(calls[0].sql, /sr\.metadata @> \$2::jsonb/);
  assert.match(calls[0].sql, /\(ir\.package_sha256 = \$3\) DESC/);
  assert.equal(calls[0].values[2], packageSha);
  assert.deepEqual(JSON.parse(calls[0].values[1] as string),
    {dataset: 'Regional', geoFips: 'STATE', tableName: 'SARPP', lineCode: '1'});
  const document = JSON.parse(calls[1].values[13] as string);
  assert.deepEqual(document.releaseMetadataContract,
    {dataset: 'Regional', geoFips: 'STATE', tableName: 'SARPP', lineCode: '1'});
  assert.equal(document.releaseRole, 'BEA_RPP_STATE');
});
