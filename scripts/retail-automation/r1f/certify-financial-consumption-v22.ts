import { Pool } from 'pg';
const pool=new Pool({connectionString:process.env.DATABASE_URL});

async function main(){
  try{
    const s=(await pool.query(`select * from retail.r1f_financial_v22_global_integrity`)).rows[0];
    if(!s) throw new Error('no R1F V2.2 repository attestation / financial status available');
    const expected=Number(s.expected_scraper_count);
    const gates=[
      {gate:'current_r1d_scraper_scope_complete',pass:expected>0&&Number(s.discovered_scraper_count)===expected&&Number(s.active_scrapers)===expected},
      {gate:'scraper_registry_hash_integrity_100',pass:Number(s.registry_hash_valid)===expected},
      {gate:'all_current_scrapers_have_execution_receipts',pass:Number(s.scrapers_with_receipts)===expected},
      {gate:'all_current_scrapers_have_provider_cost_allocations',pass:Number(s.scrapers_with_allocations)===expected},
      {gate:'execution_receipt_hash_integrity_100',pass:Number(s.receipts)>0&&Number(s.receipt_hash_valid)===Number(s.receipts)},
      {gate:'allocation_hash_integrity_100',pass:Number(s.allocations)>0&&Number(s.allocation_hash_valid)===Number(s.allocations)},
      {gate:'all_provider_periods_balanced',pass:Number(s.provider_periods)>0&&Number(s.balanced_provider_periods)===Number(s.provider_periods)},
      {gate:'no_orphan_unreconciled_bindings',pass:Number(s.orphan_unreconciled_bindings)===0},
      {gate:'no_unreconciled_authority_periods',pass:Number(s.unreconciled_authority_periods)===0},
      {gate:'paid_provider_cost_sample_exists',pass:Number(s.paid_allocations)>0}
    ];
    const allPassed=gates.every(x=>x.pass);
    console.log(JSON.stringify({
      event:'r1f_v22_financial_certification_preflight',
      allPassed,status:s,gates
    },null,2));
    if(!allPassed) process.exitCode=2;
  }finally{ await pool.end(); }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
