import { Pool } from 'pg';
const pool=new Pool({connectionString:process.env.DATABASE_URL});

async function main(){
  const binding=await pool.query(`
    select retail.r1d_r1c_binding_is_current() current
  `);
  const jobs=await pool.query(`
    select status,count(*)::int n
    from retail.r1d_dispatch_jobs
    group by status order by status
  `);
  const budgets=await pool.query(`
    select p.policy_code,p.scope_type,p.daily_limit_usd,
      coalesce(sum(
        case
          when r.status='settled' then coalesce(r.actual_usd,r.reserved_usd)
          when r.status='reserved' then r.reserved_usd
          else 0
        end
      ),0) used_or_reserved_usd
    from retail.r1d_budget_policies p
    left join retail.r1d_budget_reservations r
      on r.budget_policy_id=p.id
     and r.budget_day=(now() at time zone 'UTC')::date
    where p.active
    group by p.id,p.policy_code,p.scope_type,p.daily_limit_usd
    order by p.scope_type,p.policy_code
  `);
  const breakers=await pool.query(`
    select p.platform_code,b.collection_source_id,b.state,
           b.consecutive_failures,b.open_until
    from retail.r1d_circuit_breakers b
    join retail.retail_platforms p on p.id=b.platform_id
    where b.state<>'closed'
    order by p.platform_code
  `);
  const bindings=await pool.query(`
    select count(*)::int total,
      count(*) filter(
        where retail.r1d_dispatch_binding_is_current(id)
      )::int current
    from retail.r1d_dispatch_bindings
  `);
  console.log(JSON.stringify({
    upstreamBindingCurrent:binding.rows[0].current,
    dispatchBindings:bindings.rows[0],
    jobs:jobs.rows,
    budgets:budgets.rows,
    openCircuitBreakers:breakers.rows
  },null,2));
  await pool.end();
}
main().catch(e=>{console.error(e);process.exitCode=1;});
