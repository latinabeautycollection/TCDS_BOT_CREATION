import {randomUUID} from 'node:crypto';
import {pool} from '../core/db.js';
import {sha256} from '../core/hash.js';
import {quoteTaxV14Candidate} from '../zsl5/tax-quote-v14.service.js';

const build=process.env.ZSL5_BUILD_RUN_ID;if(!build)throw new Error('ZSL5_BUILD_RUN_ID required');
const c=await pool.connect();
try{
 const cases=(await c.query(`select * from zsl_tax_acq.runtime_test_cases where test_class='ADVERSARIAL' order by case_id`)).rows;
 for(const tc of cases){
  let status:'PASS'|'FAIL'|'NOT_EXECUTED'='NOT_EXECUTED',reason:string|null='INDEPENDENT_EVIDENCE_REQUIRED',actual:any=null;
  if(tc.status==='APPROVED'){
   const qi=tc.input_document?.quote_input,exp=tc.expected_document;
   if(!qi||!exp||!qi.transactionDate||!qi.evaluationAsOf){status='FAIL';reason='APPROVED_CASE_MISSING_FIXED_EXECUTABLE_FIXTURE'}
   else try{
    actual=await quoteTaxV14Candidate(c,build,qi,false);
    const keys=['checkoutTaxEstimateCents','estimatedLegalTaxBurdenCents','potentialUseTaxCents','mandatoryGovernmentFeesCents','totalGovernmentAcquisitionCostCents'];
    status=keys.every(k=>exp[k]===undefined||exp[k]===actual[k])?'PASS':'FAIL';reason=status==='PASS'?null:'EXPECTED_RESULT_MISMATCH';
   }catch(e){status='FAIL';reason=String(e)}
  }
  const ev={case_id:tc.case_id,status,reason,expected:tc.expected_document,actual};
  await c.query(`insert into zsl_tax_acq.runtime_test_results(test_result_id,build_run_id,case_id,state_code,test_class,status,evidence,evidence_sha256)
                 values($1,$2,$3,$4,'ADVERSARIAL',$5,$6::jsonb,$7)`,[randomUUID(),build,tc.case_id,tc.state_code,status,JSON.stringify(ev),sha256(ev)]);
 }
 console.log(JSON.stringify({cases:cases.length},null,2));
} finally {c.release();await pool.end()}
