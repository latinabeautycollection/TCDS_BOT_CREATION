import{pool,tx,advisory}from'../repositories/db.js';import{loadPolicies}from'../core/config.js';import{runChecks}from'../certification/certification.service.js';
const run=process.argv[2];if(!run)throw new Error('usage: checks <build_run_id>');const p=loadPolicies();
const id=await tx(async c=>{await advisory(c,'TCDS:ZSL3:CERTIFY');return await runChecks(c,run,p)});console.log(JSON.stringify({buildRunId:run,runtimeCheckRunId:id}));await pool.end();
