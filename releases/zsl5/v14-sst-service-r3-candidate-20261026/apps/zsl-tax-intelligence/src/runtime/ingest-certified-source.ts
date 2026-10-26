import {readFile} from 'node:fs/promises';
import {pool} from '../core/db.js';
import {canonicalJson} from '../core/hash.js';
import {validateIngestBundle} from './validate-ingest-bundle.js';
const index=process.argv.indexOf('--bundle');
if(index<0||!process.argv[index+1])throw new Error('--bundle required');
const bundle=JSON.parse(await readFile(process.argv[index+1]!,'utf8'));
await validateIngestBundle(bundle);
const header={sourceKey:bundle.sourceKey,releaseKey:bundle.releaseKey,releaseId:bundle.releaseId,
 ingestRunId:bundle.ingestRunId,artifactId:bundle.artifactId};
const c=await pool.connect();
try{
 await c.query('BEGIN');
 for(let i=0;i<bundle.records.length;i++){
  const row=bundle.records[i];
  await c.query('select zsl_tax_acq.ingest_canonical_record_v2($1::jsonb,$2::jsonb,$3::bigint,$4::text)',
   [JSON.stringify(header),JSON.stringify(row),i+1,canonicalJson(row.record)]);
 }
 await c.query('COMMIT');
 console.log(JSON.stringify({loaded:bundle.records.length,ingestRunId:bundle.ingestRunId,
  releaseId:bundle.releaseId,status:'OBSERVATIONS_STORED_NOT_CERTIFIED'},null,2));
}catch(error){await c.query('ROLLBACK');throw error}finally{c.release();await pool.end()}
