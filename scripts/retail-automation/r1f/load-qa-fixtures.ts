import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [file,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1F_ACTOR_NAME||'R1F QA Fixture Loader';

if(!file){
  throw new Error('usage: tsx load-qa-fixtures.ts <fixtures.json> [actor]');
}

async function main(){
  const fixtures=JSON.parse(await readFile(file,'utf8'));
  if(!Array.isArray(fixtures)){
    throw new Error('fixture file must be a JSON array');
  }

  const c=await pool.connect();
  let inserted=0;
  try{
    await c.query('begin');
    for(const f of fixtures){
      for(const key of [
        'fixture_code','fixture_class','input_json','expected_json'
      ]){
        if(!(key in f)){
          throw new Error(`fixture ${f.fixture_code??'?'} missing ${key}`);
        }
      }

      await c.query(`
        insert into retail.r1f_qa_fixtures(
          fixture_code,fixture_class,input_json,expected_json,
          fixture_sha256,active,created_by
        ) values(
          $1,$2,$3::jsonb,$4::jsonb,repeat('0',64),true,$5
        )
      `,[
        f.fixture_code,
        f.fixture_class,
        JSON.stringify(f.input_json),
        JSON.stringify(f.expected_json),
        actor
      ]);
      inserted++;
    }
    await c.query('commit');
    console.log(JSON.stringify({
      event:'r1f_qa_fixtures_loaded',
      inserted
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}

main().catch(e=>{console.error(e);process.exitCode=1;});
