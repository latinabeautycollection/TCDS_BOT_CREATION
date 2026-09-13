import { Pool } from 'pg';
import path from 'node:path';
import { attestableSha } from './artifact-hash';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [adapterId,repoRootArg]=process.argv.slice(2);
const repoRoot=path.resolve(repoRootArg||process.env.REPO_ROOT||process.cwd());
if(!adapterId) throw new Error('usage: tsx attest-runtime-adapter.ts <adapter_uuid> [repo_root]');

async function main(){
  const r=await pool.query(`
    select a.id,a.scraper_asset_id,
           s.implementation_root,s.implementation_authority_type
    from retail.retail_search_adapters a
    join retail.retail_scraper_assets s on s.id=a.scraper_asset_id
    where a.id=$1
  `,[adapterId]);
  if(!r.rowCount) throw new Error('adapter/scraper asset not found');

  const x=r.rows[0];
  const target=path.resolve(repoRoot,x.implementation_root);
  const observed=await attestableSha(x.implementation_authority_type,target);

  await pool.query(
    `select retail.r1b_assert_runtime_adapter($1,$2)`,
    [adapterId,observed]
  );

  console.log(JSON.stringify({
    event:'r1b_runtime_adapter_attested',
    adapterId,
    scraperAssetId:x.scraper_asset_id,
    authorityType:x.implementation_authority_type,
    implementationRoot:x.implementation_root,
    observedSha256:observed
  },null,2));
  await pool.end();
}

main().catch(e=>{console.error(e);process.exitCode=1;});
