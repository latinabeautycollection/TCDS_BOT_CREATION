import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [file,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1E_ACTOR_NAME||'R1E QA Fixture Loader';
if(!file) throw new Error('usage: tsx load-qa-fixtures.ts <fixtures.json> [actor]');

async function main(){
  const fixtures=JSON.parse(await readFile(file,'utf8'));
  if(!Array.isArray(fixtures)) throw new Error('fixtures file must be a JSON array');

  const c=await pool.connect();
  let inserted=0;
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','user',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[actor]);
    for(const f of fixtures){
      const required=[
        'fixture_code','ruleset_code','target_identity_json',
        'returned_identity_json','expected_decision','fixture_class'
      ];
      for(const k of required){
        if(!(k in f)) throw new Error(`fixture ${f.fixture_code??'?'} missing ${k}`);
      }
      await c.query(`
        insert into retail.r1e_qa_fixtures(
          fixture_code,ruleset_code,
          target_identity_json,returned_identity_json,
          expected_decision,fixture_class,
          expected_reason_family,fixture_sha256,created_by
        ) values(
          $1,$2,$3::jsonb,$4::jsonb,$5,$6,$7,repeat('0',64),$8
        )
      `,[
        f.fixture_code,f.ruleset_code,
        JSON.stringify(f.target_identity_json),
        JSON.stringify(f.returned_identity_json),
        f.expected_decision,f.fixture_class,
        f.expected_reason_family??null,actor
      ]);
      inserted++;
    }
    await c.query('commit');
    console.log(JSON.stringify({
      event:'r1e_qa_fixtures_loaded',inserted
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    throw e;
  }finally{
    c.release();await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
