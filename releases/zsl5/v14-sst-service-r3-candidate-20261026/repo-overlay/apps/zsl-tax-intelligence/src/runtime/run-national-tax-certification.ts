import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {pool} from '../core/db.js';
import {sha256} from '../core/hash.js';
import {quoteTaxV14Candidate} from '../zsl5/tax-quote-v14.service.js';

const build=process.env.ZSL5_BUILD_RUN_ID;
if(!build) throw new Error('ZSL5_BUILD_RUN_ID required');
const catalog=JSON.parse(await readFile('apps/zsl-tax-intelligence/catalog/51-state-golden-cases.json','utf8'));
const sha=/^[0-9a-f]{64}$/;

function approvedFixture(tc:any){
  const ev=tc.independent_evidence??{};
  const exp=tc.expected??{};
  return ev.review_status==='APPROVED'
    && typeof ev.authority_url==='string' && /^https:\/\//.test(ev.authority_url)
    && sha.test(String(ev.artifact_sha256??''))
    && typeof ev.reviewed_by==='string' && ev.reviewed_by.trim().length>0
    && typeof tc.transaction?.transaction_date==='string'
    && typeof tc.transaction?.evaluation_as_of==='string'
    && Number.isInteger(exp.checkout_tax_cents)
    && Number.isInteger(exp.legal_tax_burden_cents)
    && Number.isInteger(exp.mandatory_fee_cents);
}

const c=await pool.connect();
try{
  for(const tc of catalog.cases){
    const testId=randomUUID();
    let status:'PASS'|'FAIL'|'NOT_EXECUTED'='NOT_EXECUTED';
    let actual:any=null;
    let reason:string|null='INDEPENDENT_EVIDENCE_REQUIRED';
    if(tc.independent_evidence?.review_status==='APPROVED' && !approvedFixture(tc)){
      status='FAIL'; reason='APPROVED_FIXTURE_INCOMPLETE_OR_UNSEALED';
    }else if(approvedFixture(tc)){
      try{
        actual=await quoteTaxV14Candidate(c,build,{
          transactionDate:tc.transaction.transaction_date,
          evaluationAsOf:tc.transaction.evaluation_as_of,
          purchaseChannel:tc.transaction.purchase_channel,
          stateCode:tc.state_code,
          taxAddressId:tc.location_fixture?.tax_address_id??undefined,
          zip9:tc.location_fixture?.zip9??undefined,
          zip5:tc.location_fixture?.postal_code??undefined,
          zsl2LocationId:tc.location_fixture?.zsl2_location_id??undefined,
          sellerContext:tc.transaction.seller_context??{},
          buyerTaxProfile:tc.transaction.buyer_tax_profile??{},
          lines:tc.transaction.line_items.map((x:any)=>({
            lineId:x.line_id,sku:x.sku??x.line_id,quantity:x.quantity,unitPriceCents:x.unit_price_cents,
            tcdsCategoryCode:x.tcds_category_code,taxProductClass:x.tax_product_class,
            taxProductSubclass:x.tax_product_subclass,attributes:x.attributes??{},bundleId:x.bundle_id
          })),
          adjustments:tc.transaction.adjustments??[]
        },false);
        const e=tc.expected;
        status=(e.checkout_tax_cents===actual.checkoutTaxEstimateCents
          && e.legal_tax_burden_cents===actual.estimatedLegalTaxBurdenCents
          && e.mandatory_fee_cents===actual.mandatoryGovernmentFeesCents)?'PASS':'FAIL';
        reason=status==='PASS'?null:'EXPECTED_RESULT_MISMATCH';
      }catch(err){status='FAIL';reason=String(err)}
    }
    const evidence={case_id:tc.case_id,status,reason,expected:tc.expected,actual,independent_evidence:tc.independent_evidence};
    await c.query(`insert into zsl_tax_acq.runtime_test_results(test_result_id,build_run_id,case_id,state_code,test_class,status,evidence,evidence_sha256,executed_at)
                   values($1,$2,$3,$4,'GOLDEN',$5,$6::jsonb,$7,now())`,
      [testId,build,tc.case_id,tc.state_code,status,JSON.stringify(evidence),sha256(evidence)]);
  }
  const summary=(await c.query(`with latest as (
      select distinct on(case_id) case_id,state_code,status from zsl_tax_acq.runtime_test_results
       where build_run_id=$1 and test_class='GOLDEN' order by case_id,executed_at desc,test_result_id desc)
    select count(*) filter(where status='PASS')::int pass,
           count(*) filter(where status='FAIL')::int fail,
           count(*) filter(where status='NOT_EXECUTED')::int ne,
           count(distinct state_code) filter(where status='PASS')::int states
      from latest`,[build])).rows[0];
  console.log(JSON.stringify({summary},null,2));
  if(Number(summary.fail)>0||Number(summary.ne)>0||Number(summary.states)!==51) process.exitCode=2;
} finally { c.release(); await pool.end(); }
