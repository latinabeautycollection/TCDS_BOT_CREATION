import { Pool } from 'pg';
import { createHash,randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { writeFile } from 'node:fs/promises';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const packageSha=process.env.R1B_PACKAGE_SHA256;
const actor=process.env.R1B_CERTIFIER||'R1B Certification Authority';
const evidenceOut=process.env.R1B_CERT_EVIDENCE_OUT||'r1b-v4-certification-evidence.json';
const sha=(x:Buffer|string)=>createHash('sha256').update(x).digest('hex');

if(!packageSha||!/^[0-9a-f]{64}$/.test(packageSha)){
  throw new Error('R1B_PACKAGE_SHA256 must be the lowercase 64-character SHA-256 of this exact release ZIP');
}

function runJsonScript(script:string){
  try{
    const out=execFileSync(
      process.execPath,
      ['--import','tsx',script],
      {cwd:process.env.REPO_ROOT??process.cwd(),encoding:'utf8',env:process.env}
    );
    return JSON.parse(out);
  }catch(e:any){
    return {
      allExecutedPassed:false,
      allPassed:false,
      error:String(e?.stderr||e?.message||e),
      activeNegativeTests:[],
      gates:[]
    };
  }
}

async function main(){
  const c=await pool.connect();
  const correlationId=randomUUID();
  let processRunId:string|undefined;

  try{
    const run=await c.query(`
      insert into arb.process_runs(
        process_name,process_stage,status,correlation_id,
        actor_type,actor_id,actor_name,
        worker_name,worker_instance_id,code_version,ruleset_version,
        entity_type,idempotency_key
      ) values(
        'RETAIL_R1B_CERTIFY','FREEZE_GATE','STARTED',$1,
        'system','r1b-certifier',$2,
        'r1b-certify',$3,$4,'r1b-v4.0.0',
        'retail.r1b',$5
      ) returning run_id
    `,[correlationId,actor,
       process.env.WORKER_INSTANCE_ID??'r1b-cert-1',
       process.env.CODE_VERSION??'unknown',
       `R1B_CERT:${correlationId}`]);
    processRunId=run.rows[0].run_id;

    const binding=await c.query(`
      select * from retail.r1b_r1a_certification_binding where singleton=true
    `);
    if(!binding.rowCount) throw new Error('R1A certification binding missing');

    const staticChecks:any[]=[];
    const add=(name:string,ok:boolean,detail:any={})=>
      staticChecks.push({name,ok,detail});
    const count=async(sql:string)=>
      Number((await c.query(sql)).rows[0].n);

    add(
      'r1a_binding_current',
      (await c.query(`select retail.r1b_r1a_binding_is_current() ok`)).rows[0].ok===true
    );

    const integration=await c.query(`
      select run_id,status,certification_status,completed_at
      from arb.process_runs
      where process_name='RETAIL_R1B_SCRAPER_INTEGRATION_CERTIFY'
      order by coalesce(completed_at,failed_at,started_at) desc,run_id::text desc
      limit 1
    `);
    add(
      'latest_scraper_integration_certified',
      integration.rowCount===1
        && integration.rows[0].status==='SUCCEEDED'
        && integration.rows[0].certification_status==='CERTIFIED',
      integration.rows[0]??{}
    );

    const readiness=await c.query(`
      select retail.r1b_scraper_integration_readiness() x
    `);
    const ready=readiness.rows[0].x;
    add('production_scraper_scope_nonempty',ready.production_scope_nonempty===true,ready);
    add('production_scraper_scope_ready',ready.production_scope_ready===true,ready);
    add('nonempty_production_scraper_universe',ready.nonempty_production_universe===true,ready);

    add(
      'no_stale_certified_adapters',
      (await count(`
        select count(*)::int n
        from retail.retail_search_adapters
        where certification_status='certified_dynamic_search'
          and retail.r1b_adapter_execution_ready(id) is not true
      `))===0
    );

    add(
      'no_fail_open_empty_collection_capabilities',
      (await count(`
        select count(*)::int n
        from retail.retail_search_adapters
        where certification_status='certified_dynamic_search'
          and jsonb_array_length(supported_collection_methods)=0
          and supports_all_collection_methods=false
      `))===0
    );

    add(
      'no_fail_open_empty_source_capabilities',
      (await count(`
        select count(*)::int n
        from retail.retail_search_adapters
        where certification_status='certified_dynamic_search'
          and jsonb_array_length(supported_source_types)=0
          and supports_all_source_types=false
      `))===0
    );

    add(
      'all_approved_routes_current',
      (await count(`
        select count(*)::int n
        from retail.search_route_bindings
        where route_status='approved'
          and retail.r1b_route_is_current(id) is not true
      `))===0
    );

    add(
      'effective_routes_nonempty',
      (await count(`select count(*)::int n from retail.effective_search_routes`))>0
    );

    add(
      'execution_ready_adapters_nonempty',
      (await count(`
        select count(*)::int n
        from retail.retail_search_adapters
        where certification_status='certified_dynamic_search'
          and retail.r1b_adapter_execution_ready(id)=true
      `))>0
    );

    add(
      'asset_evidence_hashes_reproducible',
      (await count(`
        select count(*)::int n
        from retail.retail_scraper_assets
        where discovery_status='verified'
          and verification_evidence_sha256<>
            retail.r1b_sha256_jsonb(verification_evidence_json)
      `))===0
    );

    add(
      'contract_hashes_reproducible',
      (await count(`
        select count(*)::int n
        from retail.retail_scraper_contracts
        where certification_status in ('contract_verified','qa_passed','certified_for_r1')
          and (
            interface_evidence_sha256<>
              retail.r1b_sha256_jsonb(interface_evidence_json)
            or contract_sha256<>
              retail.r1b_sha256_jsonb(contract_document)
          )
      `))===0
    );

    const active=runJsonScript(
      'scripts/retail-automation/r1b/active-negative-tests.ts'
    );
    const scraperActive=runJsonScript(
      'scripts/retail-automation/r1b/scraper-authority-negative-tests.ts'
    );

    const activePass=active.allExecutedPassed===true;
    const scraperActivePass=scraperActive.allPassed===true;

    const evidence={
      certificationVersion:'r1b-v4.0.0',
      processRunId,
      correlationId,
      createdAt:new Date().toISOString(),
      r1aBinding:binding.rows[0],
      packageSha256:packageSha,
      scraperReadiness:ready,
      latestScraperIntegrationCertification:integration.rows[0]??null,
      staticChecks,
      activeNegativeTests:active,
      scraperAuthorityNegativeTests:scraperActive
    };

    // Seal the manifest body. The seal lives OUTSIDE the body so the stored
    // evidence and its SHA are not self-referential.
    const manifestBody=JSON.stringify(evidence);
    const manifestSha=sha(manifestBody);
    const envelope={
      manifest:evidence,
      evidenceManifestSha256:manifestSha
    };
    await writeFile(evidenceOut,JSON.stringify(envelope,null,2));

    const pass=
      staticChecks.every(x=>x.ok)
      && activePass
      && scraperActivePass;

    const activeGates=active.activeNegativeTests??[];
    const scraperGates=scraperActive.gates??[];
    const total=
      staticChecks.length+activeGates.length+scraperGates.length;
    const passed=
      staticChecks.filter(x=>x.ok).length
      +activeGates.filter((x:any)=>x.ok).length
      +scraperGates.filter((x:any)=>x.ok).length;

    await c.query(`
      insert into retail.r1b_certification_runs(
        process_run_id,certification_version,
        r1a_package_sha256,package_sha256,
        evidence_manifest,evidence_manifest_sha256,
        total_gates,passed_gates,failed_gates,
        certification_status,certified_by,completed_at
      ) values(
        $1,'r1b-v4.0.0',$2,$3,$4::jsonb,$5,$6,$7,$8,$9,$10,now()
      )
    `,[
      processRunId,
      binding.rows[0].r1a_package_sha256,
      packageSha,
      JSON.stringify(evidence),
      manifestSha,
      total,passed,total-passed,
      pass?'CERTIFIED':'FAILED',
      actor
    ]);

    await c.query(`
      update arb.process_runs
      set status=$2,
          certification_status=$3,
          certification_report_json=$4::jsonb,
          completed_at=case when $2='SUCCEEDED' then now() else completed_at end,
          failed_at=case when $2='FAILED' then now() else failed_at end,
          updated_at=now()
      where run_id=$1
    `,[
      processRunId,
      pass?'SUCCEEDED':'FAILED',
      pass?'CERTIFIED':'FAILED',
      JSON.stringify({
        evidenceManifestSha256:manifestSha,
        evidenceOut,
        staticChecks,
        activePass,
        scraperActivePass
      })
    ]);

    console.log(JSON.stringify({
      certification:pass?'CERTIFIED':'FAILED',
      processRunId,
      evidenceOut,
      evidenceManifestSha256:manifestSha,
      staticChecks,
      activeNegativeTests:active,
      scraperAuthorityNegativeTests:scraperActive
    },null,2));

    if(!pass) process.exitCode=2;
  }catch(e){
    if(processRunId){
      await c.query(`
        update arb.process_runs
        set status='FAILED',certification_status='FAILED',
            error_summary=$2,failed_at=now(),updated_at=now()
        where run_id=$1
      `,[processRunId,String((e as Error).message??e).slice(0,2000)]);
    }
    throw e;
  }finally{
    c.release();await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
