import { Pool } from 'pg';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { attestableSha } from './artifact-hash';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [
  compilationId,
  repoRootArg,
  compilerWrapperFile,
  compilerBaseMigrationFile,
  compilerHardeningMigrationFile,
  r1cPackageFile
]=process.argv.slice(2);

if(
  !compilationId||!repoRootArg||!compilerWrapperFile||
  !compilerBaseMigrationFile||!compilerHardeningMigrationFile||!r1cPackageFile
){
  throw new Error(
    'usage: tsx assert-r1d-runtime-contract.ts <compilation_uuid> <retail_repo_root> <compiler_wrapper_file> <base_migration_file> <v3_hardening_migration_file> <r1c_package_zip>'
  );
}

const fileSha=async(f:string)=>
  createHash('sha256').update(await readFile(f)).digest('hex');

async function main(){
  const job=await pool.query(`
    select * from retail.effective_compiled_search_jobs where id=$1
  `,[compilationId]);
  if(!job.rowCount) throw new Error('compilation not effective/current');
  const x=job.rows[0];

  const scraper=await pool.query(`
    select s.implementation_root,s.implementation_authority_type
    from retail.retail_search_adapters a
    join retail.retail_scraper_assets s on s.id=a.scraper_asset_id
    where a.id=$1
      and retail.r1b_adapter_execution_ready(a.id)=true
  `,[x.adapter_id]);
  if(!scraper.rowCount){
    throw new Error('R1B V4 scraper authority not execution-ready');
  }

  const s=scraper.rows[0];
  const artifactPath=path.resolve(repoRootArg,s.implementation_root);
  const observedScraperSha=await attestableSha(
    s.implementation_authority_type,
    artifactPath
  );

  const wrapperSha=await fileSha(compilerWrapperFile);
  const baseMigrationSha=await fileSha(compilerBaseMigrationFile);
  const hardeningMigrationSha=await fileSha(compilerHardeningMigrationFile);
  const packageSha=await fileSha(r1cPackageFile);

  await pool.query(
    `select retail.r1b_assert_runtime_adapter($1,$2)`,
    [x.adapter_id,observedScraperSha]
  );
  await pool.query(
    `select retail.r1c_assert_runtime_compiler_v3($1,$2,$3,$4)`,
    [
      x.compiler_version_id,
      wrapperSha,
      baseMigrationSha,
      hardeningMigrationSha
    ]
  );
  await pool.query(
    `select retail.r1c_assert_runtime_release($1,$2)`,
    [compilationId,packageSha]
  );

  console.log(JSON.stringify({
    event:'r1c_v3_r1d_runtime_contract_pass',
    compilationId,
    adapterId:x.adapter_id,
    scraperAuthorityType:s.implementation_authority_type,
    scraperImplementationRoot:s.implementation_root,
    observedScraperSha256:observedScraperSha,
    compilerWrapperSha256:wrapperSha,
    compilerBaseMigrationSha256:baseMigrationSha,
    compilerHardeningMigrationSha256:hardeningMigrationSha,
    r1cPackageSha256:packageSha
  },null,2));

  await pool.end();
}
main().catch(e=>{console.error(e);process.exitCode=1;});
