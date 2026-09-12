import { Pool,PoolClient } from 'pg';

const pool=new Pool({connectionString:process.env.DATABASE_URL});

async function mustFail(c:PoolClient,name:string,fn:()=>Promise<any>){
  await c.query('savepoint r1b_test');
  try{
    await fn();
    await c.query('rollback to savepoint r1b_test');
    return {name,ok:false,detail:'operation unexpectedly succeeded'};
  }catch(e){
    await c.query('rollback to savepoint r1b_test');
    return {name,ok:true,detail:String((e as Error).message??e)};
  }
}

async function main(){
  const c=await pool.connect();
  const results:any[]=[];
  try{
    await c.query('begin');

    const adapter=(await c.query(`
      select * from retail.retail_search_adapters
      where certification_status='certified_dynamic_search'
      order by certified_at desc limit 1
    `)).rows[0];

    const route=(await c.query(`
      select * from retail.search_route_bindings
      where route_status='approved'
      order by approved_at desc limit 1
    `)).rows[0];

    const store=(await c.query(`
      select * from retail.search_locations
      where location_type='store' and location_status='approved'
      order by approved_at desc limit 1
    `)).rows[0];

    if(adapter){
      results.push(await mustFail(c,'certified_adapter_implementation_mutation',()=>c.query(
        `update retail.retail_search_adapters set implementation_ref=implementation_ref||'.tamper' where id=$1`,[adapter.id]
      )));
      results.push(await mustFail(c,'certified_adapter_capability_mutation',()=>c.query(
        `update retail.retail_search_adapters set supports_postal_code=not supports_postal_code where id=$1`,[adapter.id]
      )));
      results.push(await mustFail(c,'runtime_wrong_sha_rejected',()=>c.query(
        `select retail.r1b_assert_runtime_adapter($1,$2)`,[adapter.id,'0'.repeat(64)]
      )));
    }

    if(route){
      results.push(await mustFail(c,'route_business_mutation',()=>c.query(
        `update retail.search_route_bindings set routing_policy=jsonb_set(routing_policy,'{tamper}','true'::jsonb) where id=$1`,[route.id]
      )));
    }

    if(store){
      results.push(await mustFail(c,'store_platform_mutation',()=>c.query(
        `update retail.search_locations set platform_id=null where id=$1`,[store.id]
      )));
    }

    await c.query('rollback');
    console.log(JSON.stringify({
      activeNegativeTests:results,
      skippedBecauseNoFixture:{
        certifiedAdapter:!adapter,
        approvedRoute:!route,
        approvedStore:!store
      },
      allExecutedPassed:results.length>0 && results.every(x=>x.ok)
    },null,2));
    if(results.length===0 || results.some(x=>!x.ok)) process.exitCode=2;
  }finally{c.release();await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
