import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {pool} from '../core/db.js';
import {sha256} from '../core/hash.js';
import {resolveTaxProductV14} from '../zsl5/tax-product-resolver-v14.js';

const build=process.env.ZSL5_BUILD_RUN_ID;if(!build)throw new Error('ZSL5_BUILD_RUN_ID required');
const catalog=JSON.parse(await readFile('apps/zsl-tax-intelligence/catalog/10-category-tax-mapping-cases.json','utf8'));
if(catalog.cases.length!==10)throw new Error('TEN_CATEGORY_CASES_REQUIRED');
const c=await pool.connect();
try{
 for(const tc of catalog.cases){
  let status:'PASS'|'FAIL'='FAIL',actual:any=null,reason:string|null=null;
  try{
   actual=await resolveTaxProductV14(c,build,tc.input);
   status=(actual.taxProductClass===tc.expected.tax_product_class && (actual.taxProductSubclass??null)===(tc.expected.tax_product_subclass??null))?'PASS':'FAIL';
   if(status==='FAIL')reason='CATEGORY_MAPPING_EXPECTED_RESULT_MISMATCH';
  }catch(e){reason=String(e)}
  const evidence={case_id:tc.case_id,authority:tc.authority,expected:tc.expected,actual,reason};
  await c.query(`insert into zsl_tax_acq.runtime_test_results(test_result_id,build_run_id,case_id,test_class,status,evidence,evidence_sha256)
                 values($1,$2,$3,'CATEGORY',$4,$5::jsonb,$6)`,[randomUUID(),build,tc.case_id,status,JSON.stringify(evidence),sha256(evidence)]);
 }
 const r=(await c.query(`select count(*) filter(where status='PASS')::int pass,count(*)::int total from zsl_tax_acq.v_runtime_test_latest where build_run_id=$1 and test_class='CATEGORY'`,[build])).rows[0];
 console.log(JSON.stringify(r,null,2));if(Number(r.pass)!==10||Number(r.total)!==10)process.exitCode=2;
}finally{c.release();await pool.end()}
