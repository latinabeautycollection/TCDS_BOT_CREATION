import { Pool } from 'pg';

const pool=new Pool({connectionString:process.env.DATABASE_URL});

type Check={name:string,pass:boolean,details?:unknown};
async function main(){
  const checks:Check[]=[];
  try{
    const roleAcl=(await pool.query(`
      with f as (
        select p.oid,p.proname,n.nspname,coalesce(p.proacl,acldefault('f',p.proowner)) acl
        from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='retail' and p.proname like 'r1f_%'
          and p.prosecdef=true
          and p.proname in(
            'r1f_register_scraper_repository_attestation','r1f_register_scraper_financial_identity',
            'r1f_register_provider_zone','r1f_record_job_provider_execution_receipt',
            'r1f_record_brightdata_zone_cost_response','r1f_record_brightdata_cost_breakdown_response',
            'r1f_promote_brightdata_bucket_to_authority_period','r1f_bind_job_to_provider_cost_period_v22',
            'r1f_reconcile_provider_cost_period_v22'
          )
      )
      select count(*)::int total,
             count(*) filter(where has_function_privilege('public',oid,'EXECUTE'))::int public_exec
      from f
    `)).rows[0];
    checks.push({name:'security_definer_public_execute_revoked',pass:Number(roleAcl.total)>=9&&Number(roleAcl.public_exec)===0,details:roleAcl});

    const hardening=(await pool.query(`
      select
        pg_get_functiondef(
          'retail.r1f_record_brightdata_cost_breakdown_response(text,date,date,integer,jsonb,uuid,text,text)'::regprocedure
        ) breakdown,
        pg_get_functiondef(
          'retail.r1f_record_brightdata_zone_cost_response(text,date,date,integer,jsonb,uuid,text,text)'::regprocedure
        ) zone,
        pg_get_functiondef(
          'retail.r1f_reconcile_provider_cost_period_v22(uuid,text)'::regprocedure
        ) reconcile,
        pg_get_functiondef(
          'retail.r1f_bind_job_to_provider_cost_period_v22(uuid,uuid,text,numeric,text)'::regprocedure
        ) bind
    `)).rows[0];
    checks.push({
      name:'daily_total_is_excluded_and_verified',
      pass:hardening.breakdown.includes("WHERE key<>'total'")&&
        hardening.breakdown.includes('cost-breakdown total mismatch')
    });
    checks.push({
      name:'dynamic_zone_account_root_supported',
      pass:hardening.zone.includes('one dynamic account object')&&
        hardening.zone.includes('v_payload_root_key')
    });
    checks.push({
      name:'dataset_day_requires_complete_execution_coverage',
      pass:hardening.reconcile.includes('dataset/day allocation requires complete R1D execution coverage')
    });
    checks.push({
      name:'snapshot_cost_is_one_to_one_direct',
      pass:hardening.bind.includes('ws_api_snaps requires DIRECT_RESOURCE attribution')&&
        hardening.reconcile.includes('exactly one directly attributed R1D job')
    });

    const workerDml=(await pool.query(`
      select count(*) filter(where
        has_table_privilege('retail_r1f_worker',format('%I.%I',schemaname,tablename),'INSERT') or
        has_table_privilege('retail_r1f_worker',format('%I.%I',schemaname,tablename),'UPDATE') or
        has_table_privilege('retail_r1f_worker',format('%I.%I',schemaname,tablename),'DELETE')
      )::int bad
      from pg_tables
      where schemaname='retail' and tablename in(
        'r1f_provider_cost_evidence','r1f_provider_cost_buckets',
        'r1f_provider_cost_breakdown_evidence','r1f_provider_daily_resource_costs',
        'r1f_provider_cost_authority_periods','r1f_provider_job_cost_bindings_v22',
        'r1f_provider_job_cost_allocations_v22'
      )
    `)).rows[0];
    checks.push({name:'generic_worker_cannot_mutate_financial_authority_tables',pass:Number(workerDml.bad)===0,details:workerDml});

    const integrity=(await pool.query(`select * from retail.r1f_financial_v22_global_integrity`)).rows[0];
    const expected=Number(integrity?.expected_scraper_count);
    checks.push({name:'current_r1d_scraper_scope_complete',pass:expected>0&&Number(integrity?.discovered_scraper_count)===expected&&Number(integrity?.active_scrapers)===expected,details:integrity});
    checks.push({name:'all_current_scrapers_have_causal_execution_receipts',pass:Number(integrity?.scrapers_with_receipts)===expected,details:integrity});
    checks.push({name:'all_current_scrapers_have_provider_cost_allocations',pass:Number(integrity?.scrapers_with_allocations)===expected,details:integrity});
    checks.push({name:'no_unreconciled_financial_debris',pass:Number(integrity?.orphan_unreconciled_bindings)===0&&Number(integrity?.unreconciled_authority_periods)===0,details:integrity});
    checks.push({name:'all_provider_periods_conserve_cost',pass:Number(integrity?.provider_periods)>0&&Number(integrity?.provider_periods)===Number(integrity?.balanced_provider_periods),details:integrity});

    const zoneProjection=(await pool.query(`
      select count(*)::int total,
        count(*) filter(where
          b.bandwidth_bytes=(e.raw_payload #>> array[b.bucket_document->>'providerAccountKey',b.bucket_key,'bw'])::bigint
          and round(b.billed_cost_usd,8)=round((e.raw_payload #>> array[b.bucket_document->>'providerAccountKey',b.bucket_key,'cost'])::numeric,8)
          and b.bucket_sha256=retail.r1f_sha256_jsonb(b.bucket_document)
          and e.raw_payload_sha256=retail.r1f_sha256_jsonb(e.raw_payload)
        )::int valid
      from retail.r1f_provider_cost_buckets b
      join retail.r1f_provider_cost_evidence e on e.id=b.evidence_id
    `)).rows[0];
    checks.push({name:'zone_cost_normalization_is_raw_payload_projection',pass:Number(zoneProjection.total)===Number(zoneProjection.valid),details:zoneProjection});

    const dup=(await pool.query(`
      select count(*)::int duplicate_jobs from(
        select r1d_job_id from retail.r1f_provider_job_cost_allocations_v22
        group by r1d_job_id having count(*)>1
      ) d
    `)).rows[0];
    checks.push({name:'single_effective_financial_authority_per_job',pass:Number(dup.duplicate_jobs)===0,details:dup});

    const overlap=(await pool.query(`
      select count(*)::int overlaps
      from retail.r1f_provider_cost_authority_periods a
      join retail.r1f_provider_cost_authority_periods b
        on a.id<b.id and a.active and b.active
       and a.provider=b.provider and a.provider_scope_key=b.provider_scope_key
       and tstzrange(a.provider_period_start,a.provider_period_end_exclusive,'[)') &&
           tstzrange(b.provider_period_start,b.provider_period_end_exclusive,'[)')
    `)).rows[0];
    checks.push({name:'no_overlapping_active_provider_authority_periods',pass:Number(overlap.overlaps)===0,details:overlap});

    const badTemporal=(await pool.query(`
      select count(*)::int bad
      from retail.r1f_provider_job_cost_bindings_v22 b
      join retail.r1f_provider_cost_authority_periods p on p.id=b.authority_period_id
      join retail.r1f_job_provider_execution_receipts r on r.id=b.execution_receipt_id
      where not (r.started_at_utc < p.provider_period_end_exclusive and r.completed_at_utc >= p.provider_period_start)
    `)).rows[0];
    checks.push({name:'all_allocated_jobs_intersect_provider_period',pass:Number(badTemporal.bad)===0,details:badTemporal});

    const allPassed=checks.every(x=>x.pass);
    console.log(JSON.stringify({event:'r1f_v22_financial_adversarial_tests',allPassed,checks},null,2));
    if(!allPassed) process.exitCode=2;
  }finally{await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
