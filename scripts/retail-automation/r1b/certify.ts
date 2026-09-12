import { Pool } from 'pg';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFile,writeFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const packageSha=process.env.R1B_PACKAGE_SHA256||null;
const actor=process.env.R1B_CERTIFIER||'R1B Certification Authority';
const evidenceOut=process.env.R1B_CERT_EVIDENCE_OUT||'r1b-v3-certification-evidence.json';
const sha=(x:Buffer|string)=>createHash('sha256').update(x).digest('hex');

async function main(){
  const c=await pool.connect();
  const correlationId=randomUUID();
  let processRunId:string|undefined;
  try{
    const run=await c.query(`
      insert into arb.process_runs(
        process_name,process_stage,status,correlation_id,actor_type,actor_id,actor_name,
        worker_name,worker_instance_id,code_version,ruleset_version,entity_type,idempotency_key
      ) values(
        'RETAIL_R1B_CERTIFY','FREEZE_GATE','STARTED',$1,'system','r1b-certifier',$2,
        'r1b-certify',$3,$4,'r1b-v3.0.0','retail.r1b',$5
      ) returning run_id
    `,[correlationId,actor,process.env.WORKER_INSTANCE_ID??'r1b-cert-1',process.env.CODE_VERSION??'unknown',`R1B_CERT:${correlationId}`]);
    processRunId=run.rows[0].run_id;

    const binding=await c.query(`select * from retail.r1b_r1a_certification_binding where singleton=true`);
    if(!binding.rowCount) throw new Error('R1A certification binding missing');

    const staticChecks:any[]=[];
    const add=(name:string,ok:boolean,detail:any={})=>staticChecks.push({name,ok,detail});
    const count=async(sql:string)=>Number((await c.query(sql)).rows[0].n);

    add('r1a_binding_current',(await c.query(`select retail.r1b_r1a_binding_is_current() ok`)).rows[0].ok===true);
    add('no_stale_certified_adapters',(await count(`
      select count(*)::int n from retail.retail_search_adapters
      where certification_status='certified_dynamic_search'
        and retail.r1b_adapter_is_certified_current(id) is not true`))===0);
    add('no_fail_open_empty_collection_capabilities',(await count(`
      select count(*)::int n from retail.retail_search_adapters
      where certification_status='certified_dynamic_search'
        and jsonb_array_length(supported_collection_methods)=0
        and supports_all_collection_methods=false`))===0);
    add('no_fail_open_empty_source_capabilities',(await count(`
      select count(*)::int n from retail.retail_search_adapters
      where certification_status='certified_dynamic_search'
        and jsonb_array_length(supported_source_types)=0
        and supports_all_source_types=false`))===0);
    add('all_approved_routes_current',(await count(`
      select count(*)::int n from retail.search_route_bindings
      where route_status='approved' and retail.r1b_route_is_current(id) is not true`))===0);
    add('effective_routes_nonempty',(await count(`select count(*)::int n from retail.effective_search_routes`))>0);
    add('certified_adapters_nonempty',(await count(`
      select count(*)::int n from retail.retail_search_adapters
      where certification_status='certified_dynamic_search'
        and retail.r1b_adapter_is_certified_current(id)=true`))>0);

    // Active negative mutation tests.
    let active:any={};
    try{
      const out=execFileSync(
        process.execPath,
        ['--import','tsx','scripts/retail-automation/r1b/active-negative-tests.ts'],
        {cwd:process.env.REPO_ROOT??process.cwd(),encoding:'utf8',env:process.env}
      );
      active=JSON.parse(out);
    }catch(e:any){
      active={allExecutedPassed:false,error:String(e?.stderr||e?.message||e)};
    }

    const evidence={
      certificationVersion:'r1b-v3.0.0',
      processRunId,correlationId,
      createdAt:new Date().toISOString(),
      r1aBinding:binding.rows[0],
      packageSha256:packageSha,
      staticChecks,
      activeNegativeTests:active
    };
    const manifestJson=JSON.stringify(evidence,null,2);
    const manifestSha=sha(manifestJson);
    (evidence as any).evidenceManifestSha256=manifestSha;
    await writeFile(evidenceOut,JSON.stringify(evidence,null,2));

    const pass=staticChecks.every(x=>x.ok)&&active.allExecutedPassed===true;
    await c.query(`
      insert into retail.r1b_certification_runs(
        process_run_id,certification_version,r1a_package_sha256,package_sha256,
        evidence_manifest,evidence_manifest_sha256,total_gates,passed_gates,failed_gates,
        certification_status,certified_by,completed_at
      ) values($1,'r1b-v3.0.0',$2,$3,$4::jsonb,$5,$6,$7,$8,$9,$10,now())
    `,[
      processRunId,binding.rows[0].r1a_package_sha256,packageSha,
      JSON.stringify(evidence),manifestSha,
      staticChecks.length+(active.activeNegativeTests?.length||0),
      staticChecks.filter(x=>x.ok).length+(active.activeNegativeTests?.filter((x:any)=>x.ok).length||0),
      staticChecks.filter(x=>!x.ok).length+(active.activeNegativeTests?.filter((x:any)=>!x.ok).length||0),
      pass?'CERTIFIED':'FAILED',actor
    ]);

    await c.query(`
      update arb.process_runs set status=$2,certification_status=$3,
        certification_report_json=$4::jsonb,completed_at=case when $2='SUCCEEDED' then now() else completed_at end,
        failed_at=case when $2='FAILED' then now() else failed_at end,updated_at=now()
      where run_id=$1
    `,[processRunId,pass?'SUCCEEDED':'FAILED',pass?'CERTIFIED':'FAILED',JSON.stringify({evidenceManifestSha256:manifestSha,evidenceOut})]);

    console.log(JSON.stringify({certification:pass?'CERTIFIED':'FAILED',processRunId,evidenceOut,evidenceManifestSha256:manifestSha,staticChecks,activeNegativeTests:active},null,2));
    if(!pass) process.exitCode=2;
  }catch(e){
    if(processRunId){
      await c.query(`update arb.process_runs set status='FAILED',certification_status='FAILED',error_summary=$2,failed_at=now(),updated_at=now() where run_id=$1`,[processRunId,String((e as Error).message??e).slice(0,2000)]);
    }
    throw e;
  }finally{c.release();await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
