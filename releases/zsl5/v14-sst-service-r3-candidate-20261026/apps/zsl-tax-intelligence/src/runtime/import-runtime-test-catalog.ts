import {readFile} from 'node:fs/promises';
import {pool} from '../core/db.js';

const files=[
  {path:'apps/zsl-tax-intelligence/catalog/51-state-golden-cases.json',cls:'GOLDEN'},
  {path:'apps/zsl-tax-intelligence/catalog/high-risk-adversarial-cases.json',cls:'ADVERSARIAL'}
] as const;

function goldenInput(x:any){
 const t=x.transaction??{};
 return {quote_input:{
   transactionDate:t.transaction_date??null,evaluationAsOf:t.evaluation_as_of??null,purchaseChannel:t.purchase_channel,
   stateCode:x.state_code,taxAddressId:x.location_fixture?.tax_address_id??undefined,zip9:x.location_fixture?.zip9??undefined,
   zip5:x.location_fixture?.postal_code??undefined,zsl2LocationId:x.location_fixture?.zsl2_location_id??undefined,
   sellerContext:t.seller_context??{},buyerTaxProfile:t.buyer_tax_profile??{},
   lines:(t.line_items??[]).map((v:any)=>({lineId:v.line_id,sku:v.sku??v.line_id,quantity:v.quantity,unitPriceCents:v.unit_price_cents,tcdsCategoryCode:v.tcds_category_code,taxProductClass:v.tax_product_class,taxProductSubclass:v.tax_product_subclass,attributes:v.attributes??{},bundleId:v.bundle_id})),
   adjustments:t.adjustments??[]
 }};
}

const c=await pool.connect();
try{
 await c.query('BEGIN');
 for(const f of files){
  const j=JSON.parse(await readFile(f.path,'utf8'));
  for(const x of j.cases){
   const input=f.cls==='GOLDEN'?goldenInput(x):(x.quote_input?{quote_input:x.quote_input}:{case_document:x});
   const evidence=x.independent_evidence??{};
   await c.query(`insert into zsl_tax_acq.runtime_test_cases(case_id,state_code,test_class,status,input_document,expected_document,independent_evidence)
                  values($1,$2,$3,'EVIDENCE_REQUIRED',$4::jsonb,$5::jsonb,$6::jsonb)
                  on conflict(case_id) do nothing`,[x.case_id,x.state_code,f.cls,JSON.stringify(input),x.expected?JSON.stringify(x.expected):null,JSON.stringify(evidence)]);
  }
 }
 await c.query('COMMIT');
}catch(e){await c.query('ROLLBACK');throw e}finally{c.release();await pool.end()}
