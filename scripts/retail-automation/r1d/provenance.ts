import { Pool } from 'pg';
import { randomUUID } from 'node:crypto';

export async function startPersistentRun(
  pool:Pool,
  processName:string,
  actorType:'user'|'worker'|'system'|'api'|'service_account',
  actorId:string,
  actorName:string,
  entityType:string,
  stage='EXECUTE'
){
  const correlationId=randomUUID();
  const r=await pool.query(`
    insert into arb.process_runs(
      process_name,process_stage,status,correlation_id,
      actor_type,actor_id,actor_name,
      worker_name,worker_instance_id,
      code_version,ruleset_version,entity_type,idempotency_key
    ) values(
      $1,$2,'STARTED',$3,$4,$5,$6,
      $7,$8,$9,'r1d-v1.0.0',$10,$11
    ) returning run_id
  `,[
    processName,stage,correlationId,actorType,actorId,actorName,
    processName.toLowerCase(),
    process.env.WORKER_INSTANCE_ID??'r1d-1',
    process.env.CODE_VERSION??process.env.GIT_SHA??'unknown',
    entityType,`${processName}:${correlationId}`
  ]);
  return {runId:r.rows[0].run_id as string,correlationId};
}

export async function finishPersistentRun(
  pool:Pool,
  runId:string,
  status:'SUCCEEDED'|'FAILED',
  counts:{seen?:number;succeeded?:number;failed?:number}={},
  error?:unknown,
  report?:Record<string,unknown>
){
  await pool.query(`
    update arb.process_runs
       set status=$2,
           rows_seen=coalesce($3,rows_seen),
           rows_succeeded=coalesce($4,rows_succeeded),
           rows_failed=coalesce($5,rows_failed),
           completed_at=case when $2='SUCCEEDED' then now() else completed_at end,
           failed_at=case when $2='FAILED' then now() else failed_at end,
           error_class=$6,
           error_summary=$7,
           details_json=case when $8::jsonb is null then details_json else $8::jsonb end,
           updated_at=now()
     where run_id=$1
  `,[
    runId,status,
    counts.seen??null,counts.succeeded??null,counts.failed??null,
    error?(error as Error).name:null,
    error?String((error as Error).message??error).slice(0,2000):null,
    report?JSON.stringify(report):null
  ]);
}
