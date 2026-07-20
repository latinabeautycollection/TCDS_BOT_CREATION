import { pool, ingestRecord } from './db.js';
import { SamsClubRecordSchema } from './types.js';
import { log } from './log.js';

async function claimBatch(limit = 100) {
  const result = await pool.query(
    `WITH candidates AS (
       SELECT id
       FROM retail.ingest_dead_letters
       WHERE source_platform='samsclub'
         AND status IN ('pending','retrying')
         AND (next_retry_at IS NULL OR next_retry_at<=now())
       ORDER BY first_failed_at
       LIMIT $1
       FOR UPDATE SKIP LOCKED
     )
     UPDATE retail.ingest_dead_letters d
        SET status='retrying', last_failed_at=now()
       FROM candidates c
      WHERE d.id=c.id
     RETURNING d.id,d.platform_id,d.collection_run_id,d.raw_payload,d.attempt_count`,
    [limit]
  );
  return result.rows;
}

async function main() {
  const rows = await claimBatch();
  for (const row of rows) {
    try {
      const parsed = SamsClubRecordSchema.parse(row.raw_payload);
      await ingestRecord(row.platform_id, row.collection_run_id, parsed);
      await pool.query(
        `UPDATE retail.ingest_dead_letters
            SET status='resolved',resolved_at=now(),next_retry_at=NULL,
                resolution_notes='Automated replay succeeded'
          WHERE id=$1`,
        [row.id]
      );
    } catch (error) {
      const abandoned = row.attempt_count >= 10;
      await pool.query(
        `UPDATE retail.ingest_dead_letters
            SET attempt_count=attempt_count+1,last_failed_at=now(),status=$2,
                next_retry_at=CASE WHEN $2='abandoned' THEN NULL
                  ELSE now()+least(interval '24 hours',interval '15 minutes'*power(2,least(attempt_count,6))) END,
                error_message=$3
          WHERE id=$1`,
        [row.id, abandoned ? 'abandoned' : 'pending', String(error).slice(0,8000)]
      );
      log('error','dlq_replay_failed',{id:row.id,error:String(error),abandoned});
    }
  }
  await pool.end();
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
