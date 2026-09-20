import { Pool } from 'pg';

const pool=new Pool({connectionString:process.env.DATABASE_URL});

async function main(){
  const q=await pool.query(`
    select jsonb_build_object(
      'base_schema_version',
        (select schema_version from retail.r1f_schema_state where singleton),
      'v2_hardening_version',
        (select hardening_version from retail.r1f_v2_state where singleton),
      'r1e_binding_current',
        retail.r1f_r1e_binding_is_current(),
      'r1f_certification_current',
        retail.r1f_latest_certification_is_current(),
      'certified_intelligence_policies',
        (select count(*) from retail.r1f_intelligence_policies
         where certification_status='certified'),
      'certified_certification_policies',
        (select count(*) from retail.r1f_certification_policies
         where certification_status='certified'),
      'v2_production_job_facts',
        (select count(*) from retail.r1f_job_facts
         where engine_version='r1f-v2.0.0' and certification_fixture=false),
      'v2_production_observations',
        (select count(*) from retail.r1f_observation_facts
         where engine_version='r1f-v2.0.0' and certification_fixture=false),
      'v2_production_snapshots',
        (select count(*) from retail.r1f_intelligence_snapshots
         where engine_version='r1f-v2.0.0' and certification_fixture=false),
      'effective_recommendations',
        (select count(*) from retail.r1f_effective_search_recommendations),
      'active_e2e_scenarios',
        (select count(*) from retail.r1f_e2e_qa_scenarios
         where active=true and scenario_type='E2E'),
      'active_concurrency_scenarios',
        (select count(*) from retail.r1f_e2e_qa_scenarios
         where active=true and scenario_type='CONCURRENCY')
    ) status
  `);

  console.log(JSON.stringify(q.rows[0].status,null,2));
  await pool.end();
}

main().catch(e=>{console.error(e);process.exitCode=1;});
