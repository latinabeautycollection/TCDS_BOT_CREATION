import { Pool } from 'pg';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [adapterId,implementationRef]=process.argv.slice(2);
if(!adapterId||!implementationRef) throw new Error('usage: tsx attest-runtime-adapter.ts <adapter_uuid> <implementation_file>');
async function main(){
  const bytes=await readFile(path.resolve(implementationRef));
  const observed=createHash('sha256').update(bytes).digest('hex');
  await pool.query(`select retail.r1b_assert_runtime_adapter($1,$2)`,[adapterId,observed]);
  console.log(JSON.stringify({event:'r1b_runtime_adapter_attested',adapterId,observedSha256:observed},null,2));
  await pool.end();
}
main().catch(e=>{console.error(e);process.exitCode=1;});
