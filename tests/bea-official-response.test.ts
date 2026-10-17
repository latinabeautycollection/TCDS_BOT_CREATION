import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {BeaRegionalRppAdapter} from '../src/adapters/bea-regional.adapter.js';

test('normalizes official BEA GeoFips and Code fields',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'bea-test-'));
  const file=join(directory,'response.json');

  await writeFile(file,JSON.stringify({
    BEAAPI:{
      Results:{
        Data:[{
          Code:'SARPP-1',
          GeoFips:'01000',
          GeoName:'Alabama',
          TimePeriod:'2024',
          CL_UNIT:'RPP',
          UNIT_MULT:'0',
          DataValue:'89.123'
        }]
      }
    }
  }));

  const adapter=new BeaRegionalRppAdapter(
    2024,
    'SARPP',
    '1',
    'STATE'
  );

  const records=[];

  for await(const record of adapter.parse({
    localPath:file
  } as any)){
    records.push(record);
  }

  assert.equal(records.length,1);

  const record=records[0];
  assert.ok(record);

  assert.equal(record.naturalKey,'01000:1:2024');
  assert.equal(record.record.GeoFIPS,'01000');
  assert.equal(record.record.LineCode,'1');
  assert.equal(adapter.validateRecord(record).valid,true);
});
