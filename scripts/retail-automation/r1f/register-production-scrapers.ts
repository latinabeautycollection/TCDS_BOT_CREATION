import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [manifestFile]=process.argv.slice(2);
const actor=process.env.R1F_ACTOR_NAME||'R1F V2.2 Financial Registry Authority';
if(!manifestFile) throw new Error('usage: tsx register-production-scrapers.ts <detected-manifest.json>');

async function main(){
  try{
    const m=JSON.parse(await readFile(manifestFile,'utf8'));
    if(!Number.isInteger(m.expectedScraperCount)||m.expectedScraperCount<1||
       m.discoveredScraperCount!==m.expectedScraperCount||
       !Array.isArray(m.scrapers)||m.scrapers.length!==m.expectedScraperCount){
      throw new Error('R1F V2.2 manifest must exactly cover current R1D scraper authority');
    }
    const incomplete=m.scrapers.filter((s:any)=>
      !s.adapterId||!s.scraperKey||!s.sourcePath||!s.sourceSha256||!s.platformId||
      !s.providerProduct||!['ZONE_COST','COST_BREAKDOWN'].includes(s.billingAuthority)||!s.serviceType||
      (
        s.billingAuthority==='ZONE_COST'
          ? !s.zoneName
          : s.billingAuthority==='COST_BREAKDOWN'
            ? !(s.datasetId||s.collectorId)
            : true
      )
    );
    if(incomplete.length){
      throw new Error(`financial mapping incomplete for ${incomplete.length} scraper(s): ${incomplete.map((x:any)=>x.sourcePath).join(', ')}`);
    }

    const att=await pool.query(`
      select retail.r1f_register_scraper_repository_attestation(
        $1,$2,$3,$4::jsonb,$5
      ) id
    `,[m.repositoryUrl,m.branchName,m.commitSha,JSON.stringify(m.scrapers),actor]);
    const attestationId=att.rows[0].id;

    const ids:any[]=[];
    for(const s of m.scrapers){
      const q=await pool.query(`
        select retail.r1f_register_scraper_financial_identity(
          $1,$2,$3,$4,$5::uuid,$6,$7,$8,$9,$10,$11,$12::jsonb,$13
        ) id
      `,[
        attestationId,s.scraperKey,s.sourcePath,s.sourceSha256,s.platformId,
        s.providerProduct,s.billingAuthority,s.serviceType,
        s.zoneName??null,s.datasetId??null,s.collectorId??null,
        JSON.stringify(s.expectedDomains||[]),actor
      ]);
      ids.push({scraperKey:s.scraperKey,id:q.rows[0].id});
    }

    const zoneMap=new Map<string,{zoneName:string,serviceType:string,billingAuthority:string}>();
    for(const s of m.scrapers){
      if(s.zoneName){
        const k=`${s.zoneName}|${s.serviceType}|${s.billingAuthority}`;
        zoneMap.set(k,{zoneName:s.zoneName,serviceType:s.serviceType,billingAuthority:s.billingAuthority});
      }
    }
    for(const z of zoneMap.values()){
      await pool.query(`
        select retail.r1f_register_provider_zone($1,$2,$3,$4)
      `,[z.zoneName,z.serviceType,z.billingAuthority,actor]);
    }

    console.log(JSON.stringify({
      event:'r1f_v22_production_scrapers_registered',
      repositoryAttestationId:attestationId,
      scraperCount:ids.length,
      scrapers:ids
    },null,2));
  }finally{ await pool.end(); }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
