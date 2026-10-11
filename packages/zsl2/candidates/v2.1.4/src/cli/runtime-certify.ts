import {pool} from '../repositories/db.js';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {canonicalJson,sha256Text} from '../core/hash.js';

const run=process.argv[2],evaluationId=process.argv[3];
if(!run||!evaluationId)throw new Error('USAGE: runtime-certify <normalization_run_uuid> <evaluation_uuid>');
const p=pool(),c=await p.connect();
const record=async(name:string,passed:boolean,measured:Record<string,unknown>)=>{
 const payload=canonicalJson({runId:run,evaluationId,name,passed,measured,algorithm:'zsl2-runtime-certify-v2.1.4'});
 const evidenceSha=sha256Text(payload);
 return c.query(`select zsl.zsl2_record_runtime_check_v214($1,$2,$3,$4,$5::jsonb,$6)`,[run,evaluationId,name,passed,JSON.stringify(measured),evidenceSha]);
};
type Attestation=Record<string,unknown> & {pass?:boolean;evidence_sha256?:string;database_snapshot_sha256?:string;query_plan_sha256?:string;file_sha256?:string};
const fileAttestation=async(path:string|undefined):Promise<Attestation>=>{if(!path)return {pass:false,reason:'ATTESTATION_NOT_SUPPLIED'};const txt=await readFile(path,'utf8');const j=JSON.parse(txt) as Record<string,unknown>;return {...j,file_sha256:createHash('sha256').update(txt).digest('hex')};};
try{
 await c.query('begin');
 const ext=await c.query(`select extname from pg_extension where extname in('postgis','pgcrypto') order by extname`);const extensions=ext.rows.map((x:Record<string,unknown>)=>String(x.extname));
 const tables=await c.query(`select to_regclass('zsl.locations') locations,to_regclass('zsl.zsl2_normalization_checkpoints') checkpoints,to_regclass('zsl.zsl2_source_snapshots') snapshots`);
 const functions=await c.query(`select to_regprocedure('zsl.zsl2_lock_source_page(uuid,text)') page_lock,to_regprocedure('zsl.zsl2_activate(uuid,uuid,text,text,jsonb,text)') activate,to_regprocedure('zsl.zsl2_revoke(uuid,uuid,text,text,jsonb,text)') revoke`);
 const preflightPass=extensions.includes('postgis')&&extensions.includes('pgcrypto')&&Object.values(tables.rows[0]??{}).every(Boolean)&&Object.values(functions.rows[0]??{}).every(Boolean);

 const integrationAtt=await fileAttestation(process.env.ZSL2_POSTGRES_INTEGRATION_ATTESTATION_PATH);
 const integrationPass=preflightPass&&integrationAtt.pass===true&&typeof integrationAtt.evidence_sha256==='string'&&/^[0-9a-f]{64}$/.test(String(integrationAtt.evidence_sha256));
 await record('postgres_integration_tests_pass',integrationPass,{preflightPass,extensions,tables:tables.rows[0],functions:functions.rows[0],attestation:integrationAtt});

 const roles=['zsl2_reader','zsl2_normalizer','zsl2_certifier','zsl2_runtime_tester','zsl2_r1b_bridge'];
 const roleRows=await c.query(`select rolname from pg_roles where rolname=any($1::text[]) order by rolname`,[roles]);
 const directAuthorityWrite=await c.query(`select has_table_privilege('zsl2_certifier','zsl.zsl2_authority_events','INSERT,UPDATE,DELETE') p`);
 const directCertWrite=await c.query(`select has_table_privilege('zsl2_certifier','zsl.zsl2_certification_runs','INSERT,UPDATE,DELETE') p`);
 const normalizerCertWrite=await c.query(`select has_table_privilege('zsl2_normalizer','zsl.zsl2_certification_runs','INSERT,UPDATE,DELETE') p`);
 const readerCanonicalWrite=await c.query(`select has_table_privilege('zsl2_reader','zsl.locations','INSERT,UPDATE,DELETE') p`);
 const rbacPass=(roleRows.rowCount??0)===roles.length&&directAuthorityWrite.rows[0]?.p===false&&directCertWrite.rows[0]?.p===false&&normalizerCertWrite.rows[0]?.p===false&&readerCanonicalWrite.rows[0]?.p===false;
 await record('rbac_runtime_pass',rbacPass,{roles:roleRows.rows,directAuthorityWrite:directAuthorityWrite.rows[0],directCertWrite:directCertWrite.rows[0],normalizerCertWrite:normalizerCertWrite.rows[0],readerCanonicalWrite:readerCanonicalWrite.rows[0]});

 const foreignSchemas=['arb','retail','zsl1','zsl3','zsl4','zsl5','zsl6','pqp','cax','orl','warehouse','shipping'];const violations:Record<string,unknown>[]=[];
 for(const schema of foreignSchemas){const exists=(await c.query(`select exists(select 1 from pg_namespace where nspname=$1) e`,[schema])).rows[0]?.e;if(!exists)continue;const q=await c.query(`select grantee,privilege_type,count(*)::int n from information_schema.role_table_grants where table_schema=$1 and grantee=any($2::text[]) and privilege_type in('INSERT','UPDATE','DELETE','TRUNCATE') group by grantee,privilege_type`,[schema,roles]);if((q.rowCount??0)>0)violations.push({schema,grants:q.rows});}
 await record('cross_domain_write_denial',violations.length===0,{foreignSchemas,violations});

 const activationFn=await c.query(`select has_function_privilege('zsl2_certifier','zsl.zsl2_activate(uuid,uuid,text,text,jsonb,text)','EXECUTE') p`);let activationPositive=false,activationNote='NO_DISPOSABLE_CERTIFIED_FIXTURE';
 const fixtureRun=process.env.ZSL2_RUNTIME_FIXTURE_RUN_ID,fixtureCert=process.env.ZSL2_RUNTIME_FIXTURE_CERT_ID;
 if(fixtureRun&&fixtureCert){await c.query('savepoint activation_probe');try{const ev={probe:true,actor:'zsl2-runtime-certify'};const q=await c.query(`select zsl.zsl2_activate($1,$2,$3,$4,$5::jsonb,$6) id`,[fixtureRun,fixtureCert,'zsl2-runtime-certify','RUNTIME_PROBE',JSON.stringify(ev),sha256Text(JSON.stringify(ev))]);activationPositive=Boolean(q.rows[0]?.id);activationNote='DISPOSABLE_FIXTURE_ACTIVATED_IN_SAVEPOINT';}finally{await c.query('rollback to savepoint activation_probe');}}
 await record('activation_runtime_pass',activationFn.rows[0]?.p===true&&activationPositive,{executePrivilege:activationFn.rows[0]?.p,positiveFixture:activationPositive,note:activationNote});

 const rollbackAtt=await fileAttestation(process.env.ZSL2_RUNTIME_ROLLBACK_ATTESTATION_PATH);const rollbackPass=rollbackAtt.pass===true&&typeof rollbackAtt.database_snapshot_sha256==='string'&&/^[0-9a-f]{64}$/.test(String(rollbackAtt.database_snapshot_sha256));
 await record('rollback_runtime_pass',rollbackPass,rollbackAtt);

 const perfAtt=await fileAttestation(process.env.ZSL2_PERFORMANCE_ATTESTATION_PATH);const perfRows=await c.query(`select count(*)::text samples,coalesce(max(duration_ms),0)::text max_ms,coalesce(percentile_cont(.99) within group(order by duration_ms),0)::text p99_ms from zsl.zsl2_performance_measurements where normalization_run_id=$1 and operation='NORMALIZE_PAGE'`,[run]);const p99=Number(String(perfRows.rows[0]?.p99_ms??'0')),max=Number(String(perfRows.rows[0]?.max_ms??'0'));const perfPass=perfAtt.pass===true&&p99<60000&&max<120000&&typeof perfAtt.query_plan_sha256==='string'&&/^[0-9a-f]{64}$/.test(String(perfAtt.query_plan_sha256));
 await record('postgres_performance_runtime_pass',perfPass,{observed:perfRows.rows[0],attestation:perfAtt,thresholds:{p99Ms:60000,maxMs:120000}});

 const lock=JSON.parse(await readFile('package-lock.json','utf8')) as {packages?:Record<string,{resolved?:string;integrity?:string}>};const missingLock=Object.entries(lock.packages??{}).filter(([k,v])=>k!==''&&(!v.resolved||!v.integrity)).map(([k])=>k);await record('dependency_freeze_complete',missingLock.length===0,{missingResolvedIntegrity:missingLock});

 const expectedContract=JSON.parse(await readFile('./config/downstream-contract.json','utf8')) as {views:Record<string,string[]>};const actualContract:Record<string,string[]>={};for(const view of Object.keys(expectedContract.views)){const q=await c.query(`select column_name from information_schema.columns where table_schema='zsl' and table_name=$1 order by ordinal_position`,[view]);actualContract[view]=q.rows.map((x:Record<string,unknown>)=>String(x.column_name));}const contractPass=Object.entries(expectedContract.views).every(([view,cols])=>JSON.stringify(cols)===JSON.stringify(actualContract[view]??[]));await record('downstream_contract_compatibility',contractPass,{expected:expectedContract.views,actual:actualContract});

 await c.query('commit');console.log(JSON.stringify({run,evaluationId,integrationPass,rbacPass,crossDomainWriteDenial:violations.length===0,activationRuntimePass:activationFn.rows[0]?.p===true&&activationPositive,rollbackPass,performancePass:perfPass,dependencyFreezeComplete:missingLock.length===0,downstreamContractCompatibility:contractPass},null,2));
}catch(e){try{await c.query('rollback')}catch{};throw e}finally{c.release();await p.end();}
