import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [file,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1E_ACTOR_NAME||'R1E V2.1 Duplicate Race Fixture Loader';

if(!file){
  throw new Error('usage: tsx load-duplicate-race-fixtures.ts <fixtures.json> [actor]');
}

async function main(){
  const fixtures=JSON.parse(await readFile(file,'utf8'));
  if(!Array.isArray(fixtures)){
    throw new Error('duplicate-race fixture file must be a JSON array');
  }

  const c=await pool.connect();
  let inserted=0;
  try{
    await c.query('begin');
    for(const f of fixtures){
      for(const k of [
        'fixture_code','capture_a_id','capture_b_id','ruleset_code'
      ]){
        if(!(k in f)) throw new Error(`fixture ${f.fixture_code??'?'} missing ${k}`);
      }

      const caps=await c.query(`
        select id,capture_metadata
        from retail.raw_product_captures
        where id=any($1::uuid[])
      `,[[f.capture_a_id,f.capture_b_id]]);

      if(caps.rowCount!==2){
        throw new Error(`both duplicate-race captures must exist for ${f.fixture_code}`);
      }
      for(const row of caps.rows){
        if(row.capture_metadata?.r1e_qa_fixture!==true){
          throw new Error(
            `duplicate-race capture ${row.id} must have capture_metadata.r1e_qa_fixture=true`
          );
        }
      }

      await c.query(`
        insert into retail.r1e_duplicate_race_fixtures(
          fixture_code,capture_a_id,capture_b_id,
          ruleset_code,fixture_sha256,active,created_by
        ) values($1,$2,$3,$4,repeat('0',64),true,$5)
      `,[
        f.fixture_code,f.capture_a_id,f.capture_b_id,
        f.ruleset_code,actor
      ]);
      inserted++;
    }
    await c.query('commit');
    console.log(JSON.stringify({
      event:'r1e_v21_duplicate_race_fixtures_loaded',
      inserted
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    throw e;
  }finally{
    c.release();await pool.end();
  }
}

main().catch(e=>{console.error(e);process.exitCode=1;});
