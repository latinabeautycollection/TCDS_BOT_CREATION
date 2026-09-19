import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const root=path.resolve(process.env.R1E_PACKAGE_ROOT||process.cwd());

async function exists(reg:string){
  const r=await pool.query(`select to_regclass($1) is not null ok`,[reg]);
  return r.rows[0].ok===true;
}

async function main(){
  const role=await pool.query(`
    select rolsuper,rolcreaterole
    from pg_roles where rolname=current_user
  `);
  const canCreateRoles=
    role.rows[0]?.rolsuper===true||role.rows[0]?.rolcreaterole===true;

  const requiredRoles=[
    'retail_r1e_reader','retail_r1e_worker','retail_r1e_certifier'
  ];
  const rs=await pool.query(`
    select rolname from pg_roles where rolname=any($1::text[])
  `,[requiredRoles]);
  const existing=new Set(rs.rows.map(x=>x.rolname));
  const missing=requiredRoles.filter(x=>!existing.has(x));

  if(!(await exists('retail.r1e_schema_state'))){
    const partial=await pool.query(`
      select array_agg(c.relname order by c.relname) objects
      from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='retail' and c.relname like 'r1e_%'
    `);
    if((partial.rows[0]?.objects??[]).length){
      throw new Error(
        `Partial R1E objects exist without schema marker: ${JSON.stringify(partial.rows[0].objects)}`
      );
    }
    if(missing.length&&!canCreateRoles){
      throw new Error(
        `R1E roles missing (${missing.join(', ')}) and current_user lacks CREATEROLE`
      );
    }

    await pool.query(await readFile(
      path.join(root,'database/migrations/038_r1e_product_match_qualification.sql'),
      'utf8'
    ));
    console.log(JSON.stringify({event:'r1e_v1_installed'}));
  }

  const base=await pool.query(`
    select schema_version from retail.r1e_schema_state where singleton=true
  `);
  if(base.rows[0]?.schema_version!=='1.0.0'){
    throw new Error(`Unsupported R1E base version ${base.rows[0]?.schema_version}`);
  }

  if(!(await exists('retail.r1e_v2_state'))){
    await pool.query(await readFile(
      path.join(root,'database/migrations/038a_r1e_v2_view_transition.sql'),
      'utf8'
    ));
    console.log(JSON.stringify({event:'r1e_v2_view_transition_applied'}));
    await pool.query(await readFile(
      path.join(root,'database/migrations/038b_r1e_v2_exact_identity_observation_hardening.sql'),
      'utf8'
    ));
    console.log(JSON.stringify({event:'r1e_v2_installed'}));
  }

  const v2=await pool.query(`
    select hardening_version from retail.r1e_v2_state where singleton=true
  `);
  if(v2.rows[0]?.hardening_version!=='2.0.0'){
    throw new Error(`Unsupported R1E V2 version ${v2.rows[0]?.hardening_version}`);
  }

  if(!(await exists('retail.r1e_v21_state'))){
    await pool.query(await readFile(
      path.join(root,'database/migrations/038c_r1e_v21_final_freeze_hardening.sql'),
      'utf8'
    ));
    console.log(JSON.stringify({event:'r1e_v21_installed'}));
  }

  const v21=await pool.query(`
    select hardening_version from retail.r1e_v21_state where singleton=true
  `);
  if(v21.rows[0]?.hardening_version!=='2.1.0'){
    throw new Error(`Unsupported R1E V2.1 version ${v21.rows[0]?.hardening_version}`);
  }

  await pool.query(await readFile(
    path.join(root,'database/migrations/038d_r1e_v21_view_grants.sql'),
    'utf8'
  ));
  console.log(JSON.stringify({event:'r1e_v21_view_grants_applied'}));

  // Prove legacy runtime functions are not executable by operational roles.
  const legacy=await pool.query(`
    select
      has_function_privilege(
        'retail_r1e_worker',
        'retail.r1e_evaluate_capture(uuid,uuid,uuid,text,text)',
        'EXECUTE'
      ) old_worker,
      has_function_privilege(
        'retail_r1e_worker',
        'retail.r1e_evaluate_capture_v2(uuid,uuid,uuid,text,text)',
        'EXECUTE'
      ) v2_worker,
      has_function_privilege(
        'retail_r1e_certifier',
        'retail.r1e_bind_r1d_certification(uuid,uuid,text,text)',
        'EXECUTE'
      ) old_bind,
      has_function_privilege(
        'retail_r1e_certifier',
        'retail.r1e_certify_ruleset(uuid,jsonb,text)',
        'EXECUTE'
      ) old_ruleset
  `);
  if(Object.values(legacy.rows[0]).some(Boolean)){
    throw new Error(`Legacy R1E authority remains executable: ${JSON.stringify(legacy.rows[0])}`);
  }

  console.log(JSON.stringify({
    event:'r1e_v21_install_complete',
    schemaVersion:'1.0.0',
    v2Hardening:'2.0.0',
    finalHardening:'2.1.0',
    legacyAuthorityRevoked:true
  },null,2));

  await pool.end();
}

main().catch(async e=>{
  console.error(e);
  await pool.end().catch(()=>undefined);
  process.exitCode=1;
});
