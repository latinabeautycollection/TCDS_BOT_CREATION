import { Pool } from 'pg';
import { randomUUID } from 'node:crypto';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const REQUIRE_22=process.env.R1B_REQUIRE_ALL_22==='true';
const MIN_CERTIFIED=Number(process.env.R1B_MIN_CERTIFIED_PRODUCTION??'1');
const actor=process.env.R1B_CERTIFIER||'R1B Scraper Integration Certifier';

async function main(){
  if(!Number.isInteger(MIN_CERTIFIED)||MIN_CERTIFIED<1){
    throw new Error('R1B_MIN_CERTIFIED_PRODUCTION must be integer >= 1');
  }

  const correlationId=randomUUID();
  const run=await pool.query(`
    insert into arb.process_runs(
      process_name,process_stage,status,correlation_id,
      actor_type,actor_id,actor_name,
      worker_name,worker_instance_id,code_version,ruleset_version,
      entity_type,idempotency_key
    ) values(
      'RETAIL_R1B_SCRAPER_INTEGRATION_CERTIFY','FREEZE_GATE','STARTED',$1,
      'system','r1b-scraper-integration-certifier',$2,
      'r1b-scraper-integration-certifier',$3,$4,'r1b-v4.0.0',
      'retail.r1b_adapter_integration_matrix',$5
    ) returning run_id
  `,[correlationId,actor,
     process.env.WORKER_INSTANCE_ID??'r1b-v4-cert-1',
     process.env.CODE_VERSION??process.env.GIT_SHA??'unknown',
     `RETAIL_R1B_SCRAPER_INTEGRATION_CERTIFY:${correlationId}`]);
  const runId=run.rows[0].run_id;

  try{
    const rr=await pool.query(`
      select retail.r1b_scraper_integration_readiness() x
    `);
    const x=rr.rows[0].x;

    const bad=await pool.query(`
      select count(*)::int n
      from retail.retail_search_adapters a
      where a.certification_status='certified_dynamic_search'
        and retail.r1b_adapter_execution_ready(a.id) is not true
    `);

    const staleRoutes=await pool.query(`
      select count(*)::int n
      from retail.search_route_bindings r
      where r.route_status='approved'
        and retail.r1b_route_is_current(r.id) is not true
    `);

    const badEvidence=await pool.query(`
      select
        (select count(*) from retail.retail_scraper_assets s
          where s.discovery_status='verified'
            and s.verification_evidence_sha256<>
                retail.r1b_sha256_jsonb(s.verification_evidence_json))::int asset_bad,
        (select count(*) from retail.retail_scraper_contracts c
          where c.certification_status in ('contract_verified','qa_passed','certified_for_r1')
            and (
              c.interface_evidence_sha256<>
                retail.r1b_sha256_jsonb(c.interface_evidence_json)
              or c.contract_sha256<>
                retail.r1b_sha256_jsonb(c.contract_document)
            ))::int contract_bad
    `);

    const checks=[
      {name:'known_repo_scrapers_inventoried',
       ok:Number(x.inventoried)>=Number(x.expected_known)},
      {name:'known_repo_scrapers_verified',
       ok:Number(x.verified)>=Number(x.expected_known)},
      {name:'nonempty_production_universe',
       ok:Number(x.certified_for_r1)>=MIN_CERTIFIED,
       detail:{certified_for_r1:x.certified_for_r1,minimum:MIN_CERTIFIED}},
      {name:'production_scope_nonempty',
       ok:x.production_scope_nonempty===true},
      {name:'production_scope_ready',
       ok:x.production_scope_ready===true},
      {name:'full_22_identity',
       ok:!REQUIRE_22||x.full_22_identified===true},
      {name:'all_certified_adapters_execution_ready',
       ok:bad.rows[0].n===0,detail:bad.rows[0]},
      {name:'no_stale_approved_routes',
       ok:staleRoutes.rows[0].n===0,detail:staleRoutes.rows[0]},
      {name:'asset_evidence_hashes_reproducible',
       ok:badEvidence.rows[0].asset_bad===0,detail:badEvidence.rows[0]},
      {name:'contract_evidence_hashes_reproducible',
       ok:badEvidence.rows[0].contract_bad===0,detail:badEvidence.rows[0]}
    ];

    const wm=await pool.query(`
      select count(*)::int n
      from retail.r1b_adapter_integration_matrix
      where platform_code='walmart'
        and r1b_certification_status='certified_for_r1'
    `);
    checks.push({
      name:'walmart_test_harness_not_certified_for_r1',
      ok:wm.rows[0].n===0,detail:wm.rows[0]
    });

    const pass=checks.every(x=>x.ok);

    await pool.query(`
      update arb.process_runs
      set status=$2,
          certification_status=$3,
          certification_report_json=$4::jsonb,
          completed_at=case when $2='SUCCEEDED' then now() else completed_at end,
          failed_at=case when $2='FAILED' then now() else failed_at end,
          updated_at=now()
      where run_id=$1
    `,[runId,pass?'SUCCEEDED':'FAILED',pass?'CERTIFIED':'FAILED',
       JSON.stringify({readiness:x,checks})]);

    console.log(JSON.stringify({
      certification:pass?'CERTIFIED':'FAILED',
      processRunId:runId,correlationId,readiness:x,checks
    },null,2));
    if(!pass) process.exitCode=2;
  }catch(e){
    await pool.query(`
      update arb.process_runs
      set status='FAILED',certification_status='FAILED',
          failed_at=now(),error_class=$2,error_summary=$3,updated_at=now()
      where run_id=$1
    `,[runId,(e as Error).name,String((e as Error).message??e).slice(0,2000)]);
    throw e;
  }finally{
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
