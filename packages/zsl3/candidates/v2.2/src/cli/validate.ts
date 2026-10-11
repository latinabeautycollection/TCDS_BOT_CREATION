import{pool,tx,advisory}from'../repositories/db.js';import{loadPolicies}from'../core/config.js';import{validateBuild}from'../validation/build-validation.service.js';
const run=process.argv[2];if(!run)throw new Error('usage: validate <build_run_id>');const p=loadPolicies();
const ev=await tx(async c=>{await advisory(c,'TCDS:ZSL3:VALIDATE');return await validateBuild(c,run,p)});console.log(JSON.stringify(ev,null,2));await pool.end();
