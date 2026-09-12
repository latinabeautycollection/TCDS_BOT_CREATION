import { Pool } from 'pg';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [r1aPackage,evidenceFile,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1B_APPROVER;
if(!r1aPackage||!evidenceFile||!actor) {
  throw new Error('usage: tsx bind-r1a-certification.ts <r1a_package.zip> <r1a_certification_evidence.json> <binder>');
}
const sha=(b:Buffer|string)=>createHash('sha256').update(b).digest('hex');

async function main(){
  const packageSha=sha(await readFile(r1aPackage));
  const evidenceSha=sha(await readFile(evidenceFile));
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`set local search_path=pg_catalog,retail`);
    const state=await c.query(`select schema_version from retail.r1a_schema_state where singleton=true`);
    if(state.rows[0]?.schema_version!=='2.0.0') throw new Error('R1A schema version must be exactly 2.0.0');

    const view=await c.query(`
      select encode(extensions.digest(convert_to(pg_get_viewdef('retail.effective_search_targets'::regclass,true),'UTF8'),'sha256'),'hex') sha
    `);

    await c.query(`
      insert into retail.r1b_r1a_certification_binding(
        singleton,r1a_schema_version,r1a_package_sha256,
        r1a_certification_evidence_sha256,r1a_effective_view_sha256,bound_by
      ) values(true,'2.0.0',$1,$2,$3,$4)
      on conflict(singleton) do update set
        r1a_schema_version=excluded.r1a_schema_version,
        r1a_package_sha256=excluded.r1a_package_sha256,
        r1a_certification_evidence_sha256=excluded.r1a_certification_evidence_sha256,
        r1a_effective_view_sha256=excluded.r1a_effective_view_sha256,
        bound_by=excluded.bound_by,bound_at=now()
    `,[packageSha,evidenceSha,view.rows[0].sha,actor]);

    // A STABLE function cannot reliably observe this transaction's new binding.
    // Validate the same predicates directly before committing.
    const ok=await c.query(`
      select coalesce((
        select
          b.r1a_schema_version='2.0.0'
          and exists(
            select 1
            from retail.r1a_schema_state s
            where s.singleton=true
              and s.schema_version=b.r1a_schema_version
          )
          and b.r1a_effective_view_sha256 =
            pg_catalog.encode(
              extensions.digest(
                pg_catalog.convert_to(
                  pg_get_viewdef(
                    'retail.effective_search_targets'::regclass,
                    true
                  ),
                  'UTF8'
                ),
                'sha256'
              ),
              'hex'
            )
        from retail.r1b_r1a_certification_binding b
        where b.singleton=true
      ),false) ok
    `);

    if(ok.rows[0]?.ok!==true) {
      throw new Error('R1A certification binding failed closed');
    }

    await c.query('commit');
    console.log(JSON.stringify({event:'r1b_r1a_certification_bound',r1aPackageSha256:packageSha,evidenceSha256:evidenceSha,viewSha256:view.rows[0].sha},null,2));
  }catch(e){await c.query('rollback');throw e;}
  finally{c.release();await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
