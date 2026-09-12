import { PoolClient } from 'pg';
import { randomUUID } from 'node:crypto';

export async function startRun(c:PoolClient, processName:string, actorType:string, actorId:string, actorName:string, entityType:string){
  const correlationId=randomUUID();
  const r=await c.query(`
    insert into arb.process_runs(
      process_name,process_stage,status,correlation_id,actor_type,actor_id,actor_name,
      worker_name,worker_instance_id,code_version,ruleset_version,entity_type,idempotency_key
    ) values($1,'EXECUTE','STARTED',$2,$3,$4,$5,$6,$7,$8,'r1b-v3.0.0',$9,$10)
    returning run_id
  `,[
    processName,correlationId,actorType,actorId,actorName,
    processName.toLowerCase(),process.env.WORKER_INSTANCE_ID??'r1b-1',
    process.env.CODE_VERSION??process.env.GIT_SHA??'unknown',
    entityType,`${processName}:${correlationId}`
  ]);
  const runId=r.rows[0].run_id;
  await c.query(`select set_config('app.actor_type',$1,true)`,[actorType]);
  await c.query(`select set_config('app.actor_id',$1,true)`,[actorId]);
  await c.query(`select set_config('app.actor_name',$1,true)`,[actorName]);
  await c.query(`select set_config('app.process_run_id',$1,true)`,[runId]);
  await c.query(`select set_config('app.correlation_id',$1,true)`,[correlationId]);
  return {runId,correlationId};
}
export async function finishRun(c:PoolClient,runId:string,status:'SUCCEEDED'|'FAILED',error?:unknown){
  await c.query(`
    update arb.process_runs set status=$2,
      completed_at=case when $2='SUCCEEDED' then now() else completed_at end,
      failed_at=case when $2='FAILED' then now() else failed_at end,
      error_class=$3,error_summary=$4,updated_at=now()
    where run_id=$1
  `,[runId,status,error?(error as Error).name:null,error?String((error as Error).message??error).slice(0,2000):null]);
}
