import { Pool,PoolClient } from 'pg';
const pool=new Pool({connectionString:process.env.DATABASE_URL});

type Gate={name:string;ok:boolean;detail?:any};
async function mustFail(c:PoolClient,name:string,fn:()=>Promise<any>):Promise<Gate>{
  await c.query(`savepoint ${name.replace(/[^a-z0-9_]/gi,'_')}`);
  const sp=name.replace(/[^a-z0-9_]/gi,'_');
  try{
    await fn();
    await c.query(`rollback to savepoint ${sp}`);
    return {name,ok:false,detail:'unexpected success'};
  }catch(e){
    await c.query(`rollback to savepoint ${sp}`);
    return {name,ok:true,detail:String((e as Error).message??e)};
  }
}

async function main(){
  const c=await pool.connect();
  const gates:Gate[]=[];
  try{
    await c.query('begin');

    const ready=await c.query(`
      select a.id
      from retail.retail_search_adapters a
      where retail.r1b_adapter_execution_ready(a.id)=true
      limit 1
    `);
    gates.push({name:'execution_ready_fixture',ok:ready.rowCount===1});

    const verifiedAsset=await c.query(`
      select id from retail.retail_scraper_assets
      where discovery_status='verified' limit 1
    `);
    if(verifiedAsset.rowCount){
      gates.push(await mustFail(c,'verified_asset_content_immutable',()=>c.query(`
        update retail.retail_scraper_assets
        set implementation_root=implementation_root||'_tamper'
        where id=$1
      `,[verifiedAsset.rows[0].id])));
    }else gates.push({name:'verified_asset_content_immutable',ok:false,detail:'no fixture'});

    const certifiedContract=await c.query(`
      select id from retail.retail_scraper_contracts
      where certification_status='certified_for_r1' limit 1
    `);
    if(certifiedContract.rowCount){
      gates.push(await mustFail(c,'certified_contract_content_immutable',()=>c.query(`
        update retail.retail_scraper_contracts
        set field_map='{}'::jsonb
        where id=$1
      `,[certifiedContract.rows[0].id])));
    }else gates.push({name:'certified_contract_content_immutable',ok:false,detail:'no fixture'});

    const certifiedAdapter=await c.query(`
      select id from retail.retail_search_adapters
      where certification_status='certified_dynamic_search' limit 1
    `);
    if(certifiedAdapter.rowCount){
      gates.push(await mustFail(c,'certified_adapter_retrofit_blocked',()=>c.query(`
        update retail.retail_search_adapters
        set scraper_asset_id=null,scraper_contract_id=null
        where id=$1
      `,[certifiedAdapter.rows[0].id])));
    }else gates.push({name:'certified_adapter_retrofit_blocked',ok:false,detail:'no fixture'});

    gates.push(await mustFail(c,'cross_platform_ingest_target_blocked',async()=>{
      const a=await c.query(`
        select a.platform_id
        from retail.retail_search_adapters a
        join retail.retail_platforms p on p.id=a.platform_id
        where p.platform_code<>'target'
        limit 1
      `);
      if(!a.rowCount) throw new Error('fixture missing');
      await c.query(`
        select retail.r1b_validate_db_ingest_targets(
          $1,'["retail.target_product_parsed"]'::jsonb
        )
      `,[a.rows[0].platform_id]);
    }));

    const bad=await c.query(`
      select count(*)::int n
      from retail.search_route_bindings r
      join retail.retail_search_adapters a on a.id=r.adapter_id
      where r.route_status='approved'
        and retail.r1b_adapter_execution_ready(a.id) is not true
        and retail.r1b_route_is_current(r.id)=true
    `);
    gates.push({
      name:'route_currentness_requires_execution_ready',
      ok:bad.rows[0].n===0,detail:bad.rows[0]
    });

    const hashBad=await c.query(`
      select count(*)::int n
      from retail.search_route_bindings r
      where r.route_status='approved'
        and r.adapter_snapshot_hash<>
          retail.r1b_sha256_jsonb(
            retail.r1b_adapter_authority_document(r.adapter_id)
          )
        and retail.r1b_route_is_current(r.id)=true
    `);
    gates.push({
      name:'route_hash_binds_scraper_authority',
      ok:hashBad.rows[0].n===0,detail:hashBad.rows[0]
    });

    const ev=await c.query(`
      select
        (select count(*) from retail.retail_scraper_assets
         where discovery_status='verified'
           and verification_evidence_sha256<>
             retail.r1b_sha256_jsonb(verification_evidence_json))::int asset_bad,
        (select count(*) from retail.retail_scraper_contracts
         where certification_status in ('contract_verified','qa_passed','certified_for_r1')
           and (interface_evidence_sha256<>
             retail.r1b_sha256_jsonb(interface_evidence_json)
           or contract_sha256<>
             retail.r1b_sha256_jsonb(contract_document)))::int contract_bad
    `);
    gates.push({
      name:'evidence_hashes_reproducible',
      ok:ev.rows[0].asset_bad===0&&ev.rows[0].contract_bad===0,
      detail:ev.rows[0]
    });

    await c.query('rollback');
    const pass=gates.every(x=>x.ok);
    console.log(JSON.stringify({allPassed:pass,gates},null,2));
    if(!pass) process.exitCode=2;
  }finally{
    c.release(); await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
