import { Pool } from 'pg';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [wrapperFile,baseMigrationFile,hardeningMigrationFile,versionArg,actorArg]=process.argv.slice(2);
const version=versionArg||'3';
const actor=actorArg||process.env.R1C_ACTOR_NAME||'R1C Compiler Registrar';

if(!wrapperFile||!baseMigrationFile||!hardeningMigrationFile){
  throw new Error(
    'usage: tsx register-compiler.ts <wrapper_file> <base_migration_file> <v3_hardening_migration_file> [version] [actor]'
  );
}
const sha=(b:Buffer|string)=>createHash('sha256').update(b).digest('hex');

async function main(){
  const wrapperSha=sha(await readFile(wrapperFile));
  const baseSha=sha(await readFile(baseMigrationFile));
  const hardeningSha=sha(await readFile(hardeningMigrationFile));

  const contract={
    schema:'r1c-compiler-contract-v3',
    upstream:'r1b-v4.0.0',
    input:'retail.effective_search_routes',
    scraper_authority:'retail.r1b_adapter_execution_ready',
    compile_profile:'retail.search_route_compile_profiles',
    output:'retail.search_job_compilations',
    deterministic:true,
    package_tree_attestation:true,
    certified_contract_required_fields_are_minimum:true,
    runtime_attestation_required:true,
    execution:false,scheduling:false,budgeting:false
  };

  const run=await startPersistentRun(
    pool,'RETAIL_R1C_COMPILER_REGISTER','service_account',
    'r1c-register',actor,'retail.search_compiler_versions'
  );

  const c=await pool.connect();
  try{
    await c.query('begin');
    const r=await c.query(`
      insert into retail.search_compiler_versions(
        compiler_code,compiler_version,
        typescript_wrapper_ref,typescript_wrapper_sha256,
        sql_migration_ref,sql_migration_sha256,
        hardening_migration_ref,hardening_migration_sha256,
        normalized_job_function_sha256,adapter_payload_function_sha256,
        compile_route_function_sha256,currentness_function_sha256,
        compiler_contract_json,compiler_contract_sha256,
        compiler_authority_sha256,certification_status,
        source_process_run_id,source_correlation_id,created_by
      ) values(
        'deterministic_route_compiler',$1,
        $2,$3,$4,$5,$6,$7,
        repeat('0',64),repeat('0',64),repeat('0',64),repeat('0',64),
        $8::jsonb,retail.r1c_sha256_jsonb($8::jsonb),
        repeat('0',64),'uncertified',
        $9,$10,$11
      )
      returning id
    `,[
      version,wrapperFile,wrapperSha,
      baseMigrationFile,baseSha,
      hardeningMigrationFile,hardeningSha,
      JSON.stringify(contract),
      run.runId,run.correlationId,actor
    ]);

    await c.query('commit');
    await finishPersistentRun(pool,run.runId,'SUCCEEDED',{seen:1,succeeded:1,failed:0});

    console.log(JSON.stringify({
      event:'r1c_v3_compiler_registered',
      compilerId:r.rows[0].id,
      wrapperSha256:wrapperSha,
      baseMigrationSha256:baseSha,
      hardeningMigrationSha256:hardeningSha,
      processRunId:run.runId,
      correlationId:run.correlationId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{seen:1,succeeded:0,failed:1},e);
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
