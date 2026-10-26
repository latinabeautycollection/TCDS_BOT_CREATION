import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
const read=(p:string)=>readFile(new URL('../../../'+p,import.meta.url),'utf8');
test('042-048 migrations do not mutate non-ZSL domains',async()=>{
 const names=(await readdir('database/migrations')).filter(x=>/^04[2-8].*\.sql$/.test(x));
 const s=(await Promise.all(names.map(x=>readFile('database/migrations/'+x,'utf8')))).join('\n').toLowerCase();
 for(const d of ['retail.','arb.','pqp.','cax.'])assert.equal(new RegExp('\\b(insert|update|delete|alter|create|drop)\\s+(table\\s+)?'+d.replace('.','\\.')).test(s),false);
});
test('final freeze has half-open temporal and state-code constraints',async()=>{
 const s=await read('database/migrations/047a_zsl5_v14_final_freeze_database_contract.sql');
 assert.match(s,/effective_to>effective_from/);assert.match(s,/\^\[A-Z\]\{2\}\$/);assert.match(s,/payload_contract_violations/);
});
test('zsl6 integration is read-only consumer contract',async()=>{
 const s=await read('database/migrations/047b_zsl5_zsl6_acquisition_cost_contract.sql');
 assert.match(s,/CREATE OR REPLACE VIEW zsl\.zsl5_zsl6_acquisition_cost_authority_v14/i);
 assert.doesNotMatch(s,/create\s+(table|schema)\s+zsl6/i);assert.doesNotMatch(s,/insert\s+into\s+zsl6/i);
});
test('raw ingest is immutable and SQL writer includes required lineage columns',async()=>{
 const cli=await read('apps/zsl-tax-intelligence/src/runtime/ingest-certified-source.ts');
 const sql=await read('database/migrations/048a_zsl1_tax_service_writer.sql');
 assert.match(cli,/await validateIngestBundle\(bundle\)/);
 assert.ok(cli.indexOf('await validateIngestBundle(bundle)')<cli.indexOf('await pool.connect()'));
 assert.match(cli,/zsl_tax_acq\.ingest_canonical_record_v2/);
 assert.doesNotMatch(cli,/insert\s+into\s+zsl(?:_raw|_tax_acq)?\./i);
 assert.doesNotMatch(sql,/on conflict\(record_sha256\) do update/i);
 assert.match(sql,/ON CONFLICT\(record_sha256\) DO NOTHING/);
 assert.match(sql,/RAW_RECORD_IMMUTABILITY_CONFLICT/);
 assert.match(sql,/RELEASE_MEMBERSHIP_IMMUTABILITY_CONFLICT/);
 assert.match(sql,/CANONICAL_METADATA_IMMUTABILITY_CONFLICT/);
 for(const k of ['release_id','artifact_id','raw_record_id','parser_version','normalization_version'])assert.match(sql,new RegExp(k));
});
test('service writer uses restricted owner and is not public executable',async()=>{
 const sql=await read('database/migrations/048a_zsl1_tax_service_writer.sql');
 assert.match(sql,/NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS/);
 assert.match(sql,/SECURITY DEFINER/);assert.match(sql,/SET search_path=pg_catalog,zsl_tax_acq,extensions,pg_temp/);
 assert.match(sql,/REVOKE ALL ON FUNCTION[^;]+FROM PUBLIC/);
 assert.match(sql,/OWNER TO zsl_tax_ingest_writer/);
 assert.match(sql,/GRANT EXECUTE ON FUNCTION[^;]+TO zsl_tax_acq_normalizer/);
 assert.doesNotMatch(sql,/GRANT\s+(?:INSERT|UPDATE|DELETE|ALL)[^;]+TO\s+zsl_tax_acq_normalizer/i);
 assert.doesNotMatch(sql,/(?:insert|update|delete)\s+(?:into\s+|from\s+)?zsl\.(?:certification_runs|zsl5_certification_runs|zsl5_authority_state)\b/i);
});
