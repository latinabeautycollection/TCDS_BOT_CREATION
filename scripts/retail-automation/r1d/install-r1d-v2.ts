import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const repoRoot=path.resolve(process.env.R1D_PACKAGE_ROOT||process.cwd());

async function tableExists(name:string){
  const r=await pool.query(`select to_regclass($1) is not null ok`,[name]);
  return r.rows[0].ok===true;
}

async function main(){
  const role=await pool.query(`
    select r.rolsuper,r.rolcreaterole
    from pg_roles r
    where r.rolname=current_user
  `);
  const canCreateRoles=role.rows[0]?.rolsuper===true||role.rows[0]?.rolcreaterole===true;

  const requiredRoles=['retail_r1d_reader','retail_r1d_scheduler','retail_r1d_dispatcher','retail_r1d_certifier'];
  const roleState=await pool.query(`
    select rolname from pg_roles where rolname=any($1::text[])
  `,[requiredRoles]);
  const existing=new Set(roleState.rows.map(x=>x.rolname));
  const missing=requiredRoles.filter(x=>!existing.has(x));

  const v1Exists=await tableExists('retail.r1d_schema_state');
  const v2Exists=await tableExists('retail.r1d_v2_state');

  if(!v1Exists){
    const unexpected=await pool.query(`
      select array_agg(c.relname order by c.relname) objects
      from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='retail'
        and c.relname like 'r1d_%'
        and c.relname<>'r1d_schema_state'
    `);
    if((unexpected.rows[0]?.objects??[]).length){
      throw new Error(
        `Partial/unknown R1D objects exist without schema marker: ${JSON.stringify(unexpected.rows[0].objects)}`
      );
    }
    if(missing.length&& !canCreateRoles){
      throw new Error(
        `R1D roles are missing (${missing.join(', ')}) and current_user lacks CREATEROLE. Pre-create roles or use an authorized migration role.`
      );
    }

    const sql=await readFile(
      path.join(repoRoot,'database/migrations/037_r1d_scheduler_dispatcher.sql'),
      'utf8'
    );
    await pool.query(sql);
    console.log(JSON.stringify({event:'r1d_v1_installed'}));
  }else{
    const state=await pool.query(`
      select schema_version from retail.r1d_schema_state where singleton=true
    `);
    if(state.rows[0]?.schema_version!=='1.0.0'){
      throw new Error(`Unsupported R1D base schema version ${state.rows[0]?.schema_version}`);
    }
    console.log(JSON.stringify({event:'r1d_v1_already_current'}));
  }

  if(!v2Exists){
    const sql=await readFile(
      path.join(repoRoot,'database/migrations/037b_r1d_v2_runtime_safety_hardening.sql'),
      'utf8'
    );
    await pool.query(sql);
    console.log(JSON.stringify({event:'r1d_v2_installed'}));
  }else{
    const state=await pool.query(`
      select hardening_version from retail.r1d_v2_state where singleton=true
    `);
    if(state.rows[0]?.hardening_version!=='2.0.0'){
      throw new Error(
        `Unsupported R1D V2 hardening version ${state.rows[0]?.hardening_version}`
      );
    }
    console.log(JSON.stringify({event:'r1d_v2_already_current'}));
  }

  const final=await pool.query(`
    select
      exists(select 1 from retail.r1d_schema_state where singleton and schema_version='1.0.0') v1,
      exists(select 1 from retail.r1d_v2_state where singleton and hardening_version='2.0.0') v2,
      retail.r1d_r1c_binding_is_current() upstream_current
  `);
  console.log(JSON.stringify({event:'r1d_install_preflight_complete',...final.rows[0]},null,2));
  await pool.end();
}

main().catch(async e=>{
  console.error(e);
  await pool.end().catch(()=>undefined);
  process.exitCode=1;
});
