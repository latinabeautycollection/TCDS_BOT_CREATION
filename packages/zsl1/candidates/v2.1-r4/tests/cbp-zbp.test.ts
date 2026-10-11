import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CensusBusinessPatternsAdapter } from '../src/adapters/census-business-patterns.adapter.js';
import type { RawSourceRecord } from '../src/core/types.js';

const exec = promisify(execFile);

test('2023 CBP and ZBP archives preserve geography, vintage, flags and source row', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'zsl-cbp-zbp-test-'));
  try {
    const cases = [
      {
        geography: 'STATE' as const, file: 'cbp23st', sourceKey: 'CENSUS_CBP',
        csv: '"fipstate","naics","lfo","est","emp","emp_nf","ap","ap_nf"\n"01","443142","-",180,1365,"J",48653,"H"\n"01","443142","C",87,1061,"J",37733,"J"\n',
        expectedKey: 'STATE:01:443142', expectedGeo: { state: '01' }
      },
      {
        geography: 'COUNTY' as const, file: 'cbp23co', sourceKey: 'CENSUS_CBP',
        csv: '"fipstate","fipscty","naics","est","emp","emp_nf","ap","ap_nf"\n"01","001","443142",5,0,"N",50,"G"\n',
        expectedKey: 'COUNTY:01001:443142', expectedGeo: { state: '01', county: '001' }
      },
      {
        geography: 'POSTAL_CODE' as const, file: 'zbp23detail', sourceKey: 'CENSUS_ZBP',
        csv: '"zip","name","naics","est"\n"00501","HOLTSVILLE, NY","443142",3\n',
        expectedKey: 'POSTAL_CODE:00501:443142', expectedGeo: { ZIPCODE: '00501' }
      }
    ];
    for (const c of cases) {
      await writeFile(join(dir, `${c.file}.txt`), c.csv);
      await exec('zip', ['-q', `${c.file}.zip`, `${c.file}.txt`], { cwd: dir });
      const adapter = new CensusBusinessPatternsAdapter(c.geography, 2023);
      const artifact = { sourceKey: c.sourceKey, releaseKey: '2023', fileName: `${c.file}.zip`,
        localPath: join(dir, `${c.file}.zip`), sourceUrl: 'https://www2.census.gov/',
        byteCount: 1, sha256: '0'.repeat(64), retrievedAt: new Date().toISOString() };
      assert.equal((await adapter.validateArtifact(artifact)).valid, true);
      const rows: RawSourceRecord[] = [];
      for await (const row of adapter.parse(artifact)) rows.push(row);
      assert.equal(rows.length, 1);
      assert.equal(rows[0]!.naturalKey, c.expectedKey);
      assert.deepEqual(Object.fromEntries(Object.keys(c.expectedGeo).map(k => [k, rows[0]!.record[k]])), c.expectedGeo);
      assert.equal(rows[0]!.record.NAICS2017, '443142');
      assert.equal(rows[0]!.record.source_row, 1);
      if (c.geography === 'COUNTY') {
        assert.equal(rows[0]!.record.EMP, null);
        assert.equal(rows[0]!.record.EMP_F, 'N');
      }
      assert.equal(adapter.validateRecord(rows[0]!).valid, true);
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
