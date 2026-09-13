import { Pool } from 'pg';
const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [platformCodesCsv,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1B_APPROVER||'R1B Production Scope Authority';
if(!platformCodesCsv) throw new Error('usage: tsx set-production-scraper-scope.ts <platform_code,platform_code,...> [actor]');
const codes=[...new Set(platformCodesCsv.split(',').map(x=>x.trim()).filter(Boolean))];
if(!codes.length) throw new Error('at least one platform required');

async function main(){
  const c=await pool.connect();
  try{
    await c.query('begin');
    const platforms=await c.query(`
      select id,platform_code
      from retail.retail_platforms
      where platform_code=any($1::text[])
    `,[codes]);
    const found=new Set(platforms.rows.map(x=>x.platform_code));
    const missing=codes.filter(x=>!found.has(x));
    if(missing.length) throw new Error(`unknown platform codes: ${missing.join(',')}`);

    await c.query(`delete from retail.r1b_production_scraper_scope`);
    for(const p of platforms.rows){
      await c.query(`
        insert into retail.r1b_production_scraper_scope(
          platform_id,is_required,required_by,notes
        ) values($1,true,$2,'Explicit R1 production launch scraper scope')
      `,[p.id,actor]);
    }
    await c.query('commit');
    console.log(JSON.stringify({
      event:'r1b_production_scraper_scope_set',
      platforms:platforms.rows
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    throw e;
  }finally{
    c.release(); await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
