import { Pool } from 'pg';
import { readFile } from 'node:fs/promises';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [file,actorArg]=process.argv.slice(2);
const actor=actorArg||process.env.R1E_ACTOR_NAME||'R1E V2.1 E2E Fixture Loader';

if(!file){
  throw new Error('usage: tsx load-e2e-fixtures.ts <fixtures.json> [actor]');
}

async function main(){
  const fixtures=JSON.parse(await readFile(file,'utf8'));
  if(!Array.isArray(fixtures)){
    throw new Error('E2E fixture file must be a JSON array');
  }

  const c=await pool.connect();
  let inserted=0;
  try{
    await c.query('begin');
    for(const f of fixtures){
      for(const k of [
        'fixture_code','raw_capture_id','ruleset_code',
        'fixture_class','expected_decision','sequence_no'
      ]){
        if(!(k in f)) throw new Error(`fixture ${f.fixture_code??'?'} missing ${k}`);
      }

      const cap=await c.query(`
        select id,capture_metadata
        from retail.raw_product_captures
        where id=$1
      `,[f.raw_capture_id]);

      if(!cap.rowCount){
        throw new Error(`raw capture ${f.raw_capture_id} does not exist`);
      }

      if(cap.rows[0].capture_metadata?.r1e_qa_fixture!==true){
        throw new Error(
          `raw capture ${f.raw_capture_id} must have capture_metadata.r1e_qa_fixture=true`
        );
      }

      await c.query(`
        insert into retail.r1e_e2e_qa_fixtures(
          fixture_code,raw_capture_id,ruleset_code,
          fixture_class,expected_decision,
          expected_reason_family,sequence_no,
          fixture_sha256,created_by
        ) values(
          $1,$2,$3,$4,$5,$6,$7,repeat('0',64),$8
        )
      `,[
        f.fixture_code,f.raw_capture_id,f.ruleset_code,
        f.fixture_class,f.expected_decision,
        f.expected_reason_family??null,
        f.sequence_no,actor
      ]);
      inserted++;
    }
    await c.query('commit');
    console.log(JSON.stringify({
      event:'r1e_v21_e2e_fixtures_loaded',
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
