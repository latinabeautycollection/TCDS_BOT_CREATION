import { Pool } from 'pg';
import { randomUUID } from 'node:crypto';
import { startPersistentRun,finishPersistentRun } from './provenance';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const count=Number(process.env.R1D_CERT_FIXTURE_COUNT??'8');
if(!Number.isInteger(count)||count<2||count>32){
  throw new Error('R1D_CERT_FIXTURE_COUNT must be integer 2..32');
}

async function main(){
  const run=await startPersistentRun(
    pool,'RETAIL_R1D_CERT_FIXTURE_PREP','system',
    'r1d-cert-fixture','R1D Certification Fixture',
    'retail.r1d_dispatch_jobs','CERT_FIXTURE'
  );
  const c=await pool.connect();
  try{
    await c.query('begin');

    // Retire any prior non-active QA fixtures.
    await c.query(`
      update retail.r1d_dispatch_jobs
      set status='cancelled',updated_at=now()
      where certification_fixture=true
        and status in('queued','retry_wait')
    `);

    const rows=await c.query(`
      select
        ec.id compilation_id,
        ec.route_authority_hash,
        ec.adapter_payload_sha256,
        ec.compiler_authority_sha256,
        ec.platform_id,ec.collection_source_id,
        ec.adapter_id,ec.location_id,
        b.id binding_id,
        s.schedule_policy_id,
        cp.id cost_profile_id,
        retail.r1d_estimate_cost(ec.id,cp.id) estimated_cost,
        sp.priority,sp.max_attempts
      from retail.effective_compiled_search_jobs ec
      join retail.r1d_compilation_schedule_state s
        on s.compilation_id=ec.id
      join retail.r1d_schedule_policies sp
        on sp.id=s.schedule_policy_id and sp.active=true
      join lateral (
        select id
        from retail.r1d_dispatch_bindings b0
        where b0.adapter_id=ec.adapter_id
          and retail.r1d_dispatch_binding_is_current(b0.id)=true
        order by b0.certified_at desc,b0.id::text
        limit 1
      ) b on true
      join retail.effective_search_routes er on er.route_id=ec.route_id
      join lateral (
        select id
        from retail.r1d_cost_profiles cp0
        where cp0.id=retail.r1d_resolve_cost_profile(
          ec.platform_id,ec.collection_source_id,er.collection_method
        )
      ) cp on true
      where exists(
        select 1 from retail.r1d_rate_policies rp
        where rp.platform_id=ec.platform_id and rp.active=true
      )
      order by ec.platform_id,ec.id
      limit $1
    `,[count]);

    if(rows.rowCount<2){
      throw new Error('At least two current multi-worker QA fixtures are required');
    }

    const fixtureIds:string[]=[];
    for(const x of rows.rows){
      const key=await c.query(`
        select retail.r1d_sha256_text($1) h
      `,[`QA:${x.compilation_id}:${run.runId}:${randomUUID()}`]);

      const r=await c.query(`
        insert into retail.r1d_dispatch_jobs(
          dispatch_key,compilation_id,route_authority_hash,
          adapter_payload_sha256,compiler_authority_sha256,
          platform_id,collection_source_id,adapter_id,location_id,
          dispatch_binding_id,cost_profile_id,schedule_policy_id,
          scheduled_for,priority,estimated_cost_usd,max_attempts,
          next_attempt_at,source_process_run_id,source_correlation_id,
          certification_fixture
        ) values(
          $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,
          now(),$13,$14,$15,now(),$16,$17,true
        )
        returning id
      `,[
        key.rows[0].h,x.compilation_id,x.route_authority_hash,
        x.adapter_payload_sha256,x.compiler_authority_sha256,
        x.platform_id,x.collection_source_id,x.adapter_id,x.location_id,
        x.binding_id,x.cost_profile_id,x.schedule_policy_id,
        x.priority,x.estimated_cost,x.max_attempts,
        run.runId,run.correlationId
      ]);
      fixtureIds.push(r.rows[0].id);
    }

    await c.query('commit');
    await finishPersistentRun(
      pool,run.runId,'SUCCEEDED',
      {seen:fixtureIds.length,succeeded:fixtureIds.length,failed:0},
      undefined,{fixtureIds}
    );
    console.log(JSON.stringify({
      event:'r1d_certification_fixtures_prepared',
      fixtureIds,processRunId:run.runId
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await finishPersistentRun(pool,run.runId,'FAILED',{},e);
    throw e;
  }finally{
    c.release();await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
