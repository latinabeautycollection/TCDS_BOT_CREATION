import { Pool } from 'pg';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const [targetId,platformCode,sourceCode,adapterCode,adapterVersion,locationCodeArg]=process.argv.slice(2);
if(!targetId||!platformCode||!sourceCode||!adapterCode||!adapterVersion){
  throw new Error('usage: tsx create-route.ts <target_uuid> <platform_code> <source_code> <adapter_code> <adapter_version> [location_code]');
}
const actor=process.env.R1B_ACTOR_NAME??'R1B Route Service';

async function main(){
  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','service_account',true)`);
    await c.query(`select set_config('app.actor_id','r1b-route-service',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[actor]);

    const t=await c.query(`select * from retail.effective_search_targets where target_id=$1`,[targetId]);
    if(!t.rowCount) throw new Error('R1A target is not effective');

    const p=await c.query(`select * from retail.retail_platforms where platform_code=$1`,[platformCode]);
    if(!p.rowCount) throw new Error('platform not registered');

    const s=await c.query(
      `select * from retail.platform_collection_sources
       where platform_id=$1 and source_code=$2`,
      [p.rows[0].id,sourceCode]
    );
    if(!s.rowCount) throw new Error('source not found for platform');

    const a=await c.query(
      `select * from retail.retail_search_adapters
       where platform_id=$1 and adapter_code=$2 and adapter_version=$3`,
      [p.rows[0].id,adapterCode,adapterVersion]
    );
    if(!a.rowCount) throw new Error('adapter version not found for platform');

    let locationId:string|null=null;
    if(locationCodeArg){
      const l=await c.query(`select * from retail.search_locations where location_code=$1`,[locationCodeArg]);
      if(!l.rowCount) throw new Error('location not found');
      if(l.rows[0].location_type==='store' && l.rows[0].platform_id!==p.rows[0].id){
        throw new Error('cross-retailer store identity blocked');
      }
      locationId=l.rows[0].id;
    }

    const e=t.rows[0];
    const routeCode=[
      'R1B',e.target_code,platformCode.toUpperCase(),
      sourceCode.toUpperCase(),adapterCode.toUpperCase(),
      `V${adapterVersion.toUpperCase()}`,
      (locationCodeArg??'NATIONAL').toUpperCase()
    ].join(':').replace(/[^A-Z0-9_:-]/g,'_');

    const r=await c.query(
      `insert into retail.search_route_bindings(
         route_code,target_id,r1a_revision_id,r1a_revision_hash,
         platform_id,collection_source_id,adapter_id,location_id,
         route_status,routing_policy,
         platform_snapshot,platform_snapshot_hash,
         source_snapshot,source_snapshot_hash,
         adapter_snapshot,adapter_snapshot_hash,
         location_snapshot,location_snapshot_hash,
         route_authority_hash,created_by
       ) values(
         $1,$2,$3,$4,$5,$6,$7,$8,'draft',
         jsonb_build_object(
           'authority','R1B',
           'source_type_authority','R1B',
           'r1a_desired_source_types_authoritative',false,
           'schedule_authority',false,
           'budget_authority',false,
           'purchase_authority',false
         ),
         '{}'::jsonb,repeat('0',64),
         '{}'::jsonb,repeat('0',64),
         '{}'::jsonb,repeat('0',64),
         null,null,repeat('0',64),$9
       )
       returning id,route_code,route_status,route_authority_hash`,
      [
        routeCode,e.target_id,e.revision_id,e.revision_hash,
        p.rows[0].id,s.rows[0].id,a.rows[0].id,locationId,actor
      ]
    );

    await c.query('commit');
    console.log(JSON.stringify({event:'r1b_route_created',...r.rows[0]},null,2));
  }catch(e){await c.query('rollback');throw e;}
  finally{c.release();await pool.end();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
