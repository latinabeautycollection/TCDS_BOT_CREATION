import {randomUUID} from 'node:crypto';
import {pool} from '../core/db.js';
import {quoteTaxV14Candidate} from '../zsl5/tax-quote-v14.service.js';
import {sha256,canonicalJson} from '../core/hash.js';

const build=process.env.ZSL5_BUILD_RUN_ID;if(!build)throw new Error('ZSL5_BUILD_RUN_ID required');
const c=await pool.connect();
try{
 const tc=(await c.query(`select * from zsl_tax_acq.runtime_test_cases where test_class='GOLDEN' and status='APPROVED' order by case_id limit 1`)).rows[0];
 if(!tc){
  const ev={reason:'NO_APPROVED_GOLDEN_CASE'};
  await c.query(`insert into zsl_tax_acq.runtime_test_results(test_result_id,build_run_id,case_id,test_class,status,evidence,evidence_sha256)
                 values($1,$2,'REPLAY-001','REPLAY','NOT_EXECUTED',$3::jsonb,$4)`,[randomUUID(),build,JSON.stringify(ev),sha256(ev)]);process.exitCode=2;
 }else{
  const qi=tc.input_document.quote_input;
  if(!qi?.transactionDate||!qi?.evaluationAsOf)throw new Error('GOLDEN_CASE_FIXED_EVALUATION_TIME_REQUIRED_FOR_REPLAY');
  const a=await quoteTaxV14Candidate(c,build,qi,false),b=await quoteTaxV14Candidate(c,build,qi,false);
  const pass=canonicalJson(a)===canonicalJson(b);const ev={case_id:tc.case_id,first:a,second:b};
  await c.query(`insert into zsl_tax_acq.runtime_test_results(test_result_id,build_run_id,case_id,state_code,test_class,status,evidence,evidence_sha256)
                 values($1,$2,'REPLAY-001',$3,'REPLAY',$4,$5::jsonb,$6)`,[randomUUID(),build,tc.state_code,pass?'PASS':'FAIL',JSON.stringify(ev),sha256(ev)]);
  if(!pass)process.exitCode=2;
 }
}finally{c.release();await pool.end()}
