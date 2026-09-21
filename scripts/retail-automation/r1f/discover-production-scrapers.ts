import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFile,writeFile } from 'node:fs/promises';
import path from 'node:path';
import { Pool } from 'pg';

const repoRoot=path.resolve(process.env.REPO_ROOT||process.argv[2]||process.cwd());
const overridesFile=process.env.R1F_SCRAPER_OVERRIDES||
  path.resolve(process.cwd(),'config/r1f-production-scraper-financial-overrides.json');
const outFile=process.env.R1F_SCRAPER_MANIFEST_OUT||
  path.resolve(process.cwd(),'r1f-production-scraper-manifest.detected.json');

const sha=(b:Buffer|string)=>createHash('sha256').update(b).digest('hex');

function detectProviderProduct(text:string){
  if(/\/datasets\/v3\/(trigger|scrape|progress|snapshot)/i.test(text))
    return {providerProduct:'WEB_SCRAPER_API',billingAuthority:'COST_BREAKDOWN',serviceType:'WEB_SCRAPER'};
  if(/\/dca\/(trigger|crawl|dataset)/i.test(text))
    return {providerProduct:'SCRAPER_STUDIO',billingAuthority:'COST_BREAKDOWN',serviceType:'SCRAPER_STUDIO'};
  if(/brd\.superproxy\.io|proxy[_-]?zone|BRIGHTDATA.*PROXY|BRIGHT_DATA.*PROXY/i.test(text))
    return {providerProduct:'ZONE_PROXY',billingAuthority:'ZONE_COST',serviceType:'RESIDENTIAL_PROXY'};
  if(/api\.brightdata\.com\/request|WEB[_-]?UNLOCKER|UNLOCKER/i.test(text))
    return {providerProduct:'WEB_UNLOCKER',billingAuthority:null,serviceType:'UNLOCKER'};
  if(/BROWSER[_-]?API|brd\.superproxy\.io.*9222|playwright.*brightdata|puppeteer.*brightdata/i.test(text))
    return {providerProduct:'BROWSER_API',billingAuthority:null,serviceType:'BROWSER'};
  if(/SERP[_-]?API|api\.brightdata\.com\/serp/i.test(text))
    return {providerProduct:'SERP_API',billingAuthority:null,serviceType:'SERP'};
  return null;
}

async function main(){
  const pool=new Pool({connectionString:process.env.DATABASE_URL});
  let overrides:any={scrapers:[]};
  try{ overrides=JSON.parse(await readFile(overridesFile,'utf8')); }catch{}
  const overrideByPath=new Map<string,any>(
    (overrides.scrapers||[]).map((x:any)=>[String(x.sourcePath).replaceAll('\\','/'),x])
  );

  const authority=(await pool.query(`
    select distinct
      compiled.adapter_id::text "adapterId",
      adapter.adapter_code "adapterCode",
      compiled.platform_id::text "platformId",
      asset.entrypoint_ref "sourcePath"
    from retail.effective_compiled_search_jobs compiled
    join retail.retail_search_adapters adapter on adapter.id=compiled.adapter_id
    join retail.retail_scraper_assets asset on asset.id=adapter.scraper_asset_id
    where exists(
      select 1
      from retail.r1d_dispatch_bindings binding
      where binding.adapter_id=compiled.adapter_id
        and retail.r1d_dispatch_binding_is_current(binding.id)=true
    )
    order by adapter.adapter_code,asset.entrypoint_ref
  `)).rows;
  await pool.end();
  if(!authority.length){
    throw new Error('FAIL-CLOSED: current certified/effective R1D scraper scope is empty');
  }

  const candidates:any[]=[];
  for(const current of authority){
    const rel=String(current.sourcePath).replaceAll('\\','/');
    const buf=await readFile(path.join(repoRoot,rel));
    const text=buf.toString('utf8');
    const detected=detectProviderProduct(text);
    const ov=overrideByPath.get(rel)||{};
    if(!detected&&!ov.providerProduct){
      throw new Error(`financial provider mapping required for current R1D scraper ${rel}`);
    }
    candidates.push({
      adapterId:current.adapterId,
      scraperKey:ov.scraperKey||current.adapterCode,
      sourcePath:rel,
      sourceSha256:sha(buf),
      providerProduct:ov.providerProduct||detected?.providerProduct,
      billingAuthority:ov.billingAuthority||detected?.billingAuthority,
      serviceType:ov.serviceType||detected?.serviceType,
      platformId:ov.platformId||current.platformId,
      zoneName:ov.zoneName||null,
      datasetId:ov.datasetId||null,
      collectorId:ov.collectorId||null,
      expectedDomains:ov.expectedDomains||[]
    });
  }

  for(const rel of overrideByPath.keys()){
    if(!candidates.some(x=>x.sourcePath===rel)){
      throw new Error(`override path is outside current R1D scraper authority: ${rel}`);
    }
  }

  candidates.sort((a,b)=>a.sourcePath.localeCompare(b.sourcePath));
  const uniquePaths=new Set(candidates.map(x=>x.sourcePath));
  const uniqueKeys=new Set(candidates.map(x=>x.scraperKey));
  const uniqueAdapters=new Set(candidates.map(x=>x.adapterId));
  if(uniquePaths.size!==candidates.length||uniqueKeys.size!==candidates.length||
     uniqueAdapters.size!==candidates.length){
    throw new Error('duplicate adapterId, scraper sourcePath, or scraperKey detected');
  }
  if(candidates.length!==authority.length){
    throw new Error(
      `FAIL-CLOSED: discovered ${candidates.length} scraper candidates for `+
      `${authority.length} current R1D adapters`
    );
  }

  const commitSha=execFileSync('git',['rev-parse','HEAD'],{cwd:repoRoot,encoding:'utf8'}).trim().toLowerCase();
  const branchName=execFileSync('git',['branch','--show-current'],{cwd:repoRoot,encoding:'utf8'}).trim()||'DETACHED';
  if(!/^[0-9a-f]{40}$/.test(commitSha)) throw new Error('full git commit SHA unavailable');

  const manifest={
    schemaVersion:'r1f-scraper-financial-manifest-v2.2',
    authorityScope:'current-certified-effective-r1d-adapters',
    repositoryUrl:overrides.repositoryUrl||'https://github.com/latinabeautycollection/TCDS_BOT_CREATION',
    branchName,
    commitSha,
    expectedScraperCount:authority.length,
    discoveredScraperCount:candidates.length,
    scrapers:candidates
  };
  await writeFile(outFile,JSON.stringify(manifest,null,2)+'\n');
  console.log(JSON.stringify({event:'r1f_v22_scraper_manifest_discovered',outFile,...manifest},null,2));
}
main().catch(e=>{console.error(e);process.exitCode=1;});
