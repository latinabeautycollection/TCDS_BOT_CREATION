import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const root=path.resolve(process.env.R1F_PACKAGE_ROOT||process.cwd());

async function main(){
  const role=await pool.query(`
    select rolsuper,rolcreaterole
    from pg_roles where rolname=current_user
  `);

  const canCreateRoles=
    role.rows[0]?.rolsuper===true||role.rows[0]?.rolcreaterole===true;

  const requiredRoles=[
    'retail_r1f_reader','retail_r1f_worker','retail_r1f_certifier'
  ];

  const rs=await pool.query(`
    select rolname from pg_roles where rolname=any($1::text[])
  `,[requiredRoles]);

  const existing=new Set(rs.rows.map(x=>x.rolname));
  const missing=requiredRoles.filter(x=>!existing.has(x));

  const base=await pool.query(`
    select to_regclass('retail.r1f_schema_state') is not null installed
  `);

  if(!base.rows[0].installed){
    const partial=await pool.query(`
      select array_agg(c.relname order by c.relname) objects
      from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='retail'
        and c.relname like 'r1f_%'
    `);

    if((partial.rows[0]?.objects??[]).length){
      throw new Error(
        `Partial R1F objects exist without schema marker: ${JSON.stringify(partial.rows[0].objects)}`
      );
    }

    if(missing.length&&!canCreateRoles){
      throw new Error(
        `R1F roles missing (${missing.join(', ')}) and current_user lacks CREATEROLE`
      );
    }

    await pool.query(await readFile(
      path.join(root,'database/migrations/039_r1f_search_intelligence.sql'),
      'utf8'
    ));

    console.log(JSON.stringify({event:'r1f_v1_base_installed'}));
  }

  const v1=await pool.query(`
    select schema_version
    from retail.r1f_schema_state
    where singleton=true
  `);

  if(v1.rows[0]?.schema_version!=='1.0.0'){
    throw new Error(`Unsupported R1F base version ${v1.rows[0]?.schema_version}`);
  }

  const v2state=await pool.query(`
    select to_regclass('retail.r1f_v2_state') is not null installed
  `);

  if(!v2state.rows[0].installed){
    await pool.query(await readFile(
      path.join(
        root,
        'database/migrations/039b_r1f_v2_nationwide_economic_hardening.sql'
      ),
      'utf8'
    ));
    console.log(JSON.stringify({event:'r1f_v2_hardening_installed'}));
  }

  const v2=await pool.query(`
    select hardening_version
    from retail.r1f_v2_state
    where singleton=true
  `);

  if(v2.rows[0]?.hardening_version!=='2.0.0'){
    throw new Error(`Unsupported R1F V2 version ${v2.rows[0]?.hardening_version}`);
  }

  const legacy=await pool.query(`
    select
      has_function_privilege(
        'retail_r1f_worker',
        'retail.r1f_ingest_completed_job(uuid,uuid,text,text)',
        'EXECUTE'
      ) old_ingest,
      has_function_privilege(
        'retail_r1f_worker',
        'retail.r1f_build_intelligence(uuid,timestamptz,uuid,text,text)',
        'EXECUTE'
      ) old_build,
      has_function_privilege(
        'retail_r1f_worker',
        'retail.r1f_generate_recommendations(uuid,timestamptz,uuid,text,text)',
        'EXECUTE'
      ) old_recommend
  `);

  if(Object.values(legacy.rows[0]).some(Boolean)){
    throw new Error(
      `Legacy R1F V1 runtime authority remains executable: ${JSON.stringify(legacy.rows[0])}`
    );
  }

  console.log(JSON.stringify({
    event:'r1f_v2_install_complete',
    baseSchemaVersion:'1.0.0',
    hardeningVersion:'2.0.0',
    legacyRuntimeAuthorityRevoked:true
  },null,2));

  await pool.end();
}

main().catch(async e=>{
  console.error(e);
  await pool.end().catch(()=>undefined);
  process.exitCode=1;
});
