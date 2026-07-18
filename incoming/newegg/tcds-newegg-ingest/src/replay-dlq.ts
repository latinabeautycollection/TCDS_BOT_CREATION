import { pool, ingestRecord } from "./db.js";
import { NeweggRecordSchema } from "./types.js";
import { log } from "./log.js";

async function claimNext() {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await client.query(`SELECT id,platform_id,collection_run_id,raw_payload,attempt_count FROM retail.ingest_dead_letters WHERE source_platform='newegg' AND status IN('pending','retrying') AND (next_retry_at IS NULL OR next_retry_at<=now()) ORDER BY first_failed_at LIMIT 1 FOR UPDATE SKIP LOCKED`);
    const row = result.rows[0];
    if (row) await client.query(`UPDATE retail.ingest_dead_letters SET status='retrying',last_failed_at=now() WHERE id=$1`, [row.id]);
    await client.query("COMMIT");
    return row;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally { client.release(); }
}

async function main() {
  for (let processed=0; processed<100; processed++) {
    const row=await claimNext();
    if (!row) break;
    try {
      const record=NeweggRecordSchema.parse(row.raw_payload);
      await ingestRecord(row.platform_id,row.collection_run_id,record);
      await pool.query(`UPDATE retail.ingest_dead_letters SET status='resolved',resolved_at=now(),next_retry_at=NULL,resolution_notes='Automated replay succeeded' WHERE id=$1`,[row.id]);
    } catch(error) {
      const abandoned=Number(row.attempt_count)+1>=10;
      await pool.query(`UPDATE retail.ingest_dead_letters SET attempt_count=attempt_count+1,last_failed_at=now(),status=$2,next_retry_at=CASE WHEN $2='abandoned' THEN NULL ELSE now()+least(interval '24 hours',interval '15 minutes'*power(2,least(attempt_count,6))) END,error_message=$3 WHERE id=$1`,[row.id,abandoned?'abandoned':'pending',String(error).slice(0,8000)]);
      log('error','dlq_replay_failed',{id:row.id,error:String(error),abandoned});
    }
  }
  await pool.end();
}
main().catch(error=>{console.error(error);process.exitCode=1;});
