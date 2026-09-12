import { Pool } from 'pg';

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const [targetId, revArg, actorArg] = process.argv.slice(2);
const revisionNo = Number(revArg);
const actor = actorArg || process.env.R1A_APPROVER;

if (!targetId || !Number.isInteger(revisionNo) || revisionNo <= 0 || !actor) {
  throw new Error(
    'usage: tsx approve-revision.ts <target_uuid> <revision_no> <approver>'
  );
}

const c = await pool.connect();
try {
  await c.query('begin');

  await c.query(`select set_config('app.actor_type','user',true)`);
  await c.query(`select set_config('app.actor_id',$1,true)`, [actor]);
  await c.query(`select set_config('app.actor_name',$1,true)`, [actor]);

  // Lock target first to serialize approval races.
  const target = await c.query(
    `select *
       from retail.search_targets
      where id=$1
      for update`,
    [targetId]
  );
  if (!target.rowCount) throw new Error('target not found');

  const revision = await c.query(
    `select r.*,
            retail.r1a_revision_is_current(r.target_id,r.revision_no) as is_current,
            retail.r1a_sha256_jsonb(retail.r1a_revision_business_document(r))
              = r.revision_hash as revision_hash_valid
       from retail.search_target_revisions r
      where r.target_id=$1
        and r.revision_no=$2
      for update`,
    [targetId, revisionNo]
  );

  if (!revision.rowCount) throw new Error('revision not found');
  const r = revision.rows[0];

  if (r.approval_status === 'rejected' || r.approval_status === 'superseded') {
    throw new Error(`${r.approval_status} revision cannot be approved; create a new revision`);
  }
  if (target.rows[0].status === 'retired') {
    throw new Error('retired target cannot be reactivated');
  }
  if (r.is_current !== true) {
    throw new Error('approval blocked: revision is stale against current ARB authority');
  }
  if (r.revision_hash_valid !== true) {
    throw new Error('approval blocked: revision hash mismatch');
  }

  // Supersede any prior approved revision first.
  await c.query(
    `update retail.search_target_revisions
        set approval_status='superseded'
      where target_id=$1
        and revision_no<>$2
        and approval_status='approved'`,
    [targetId, revisionNo]
  );

  await c.query(
    `update retail.search_target_revisions
        set approval_status='approved',
            approved_by=$3,
            approved_at=now()
      where target_id=$1
        and revision_no=$2`,
    [targetId, revisionNo, actor]
  );

  await c.query(
    `update retail.search_targets
        set current_revision_no=$2,
            approved_by=$3,
            approved_at=now(),
            status='active'
      where id=$1`,
    [targetId, revisionNo, actor]
  );

  // Final assertion after all lifecycle changes.
  const finalCheck = await c.query(
    `select exists(
       select 1
       from retail.effective_search_targets
       where target_id=$1
         and current_revision_no=$2
     ) as effective`,
    [targetId, revisionNo]
  );
  if (finalCheck.rows[0]?.effective !== true) {
    throw new Error('approval failed closed: target did not become effective');
  }

  await c.query('commit');
  console.log(JSON.stringify({
    event: 'r1a_revision_approved',
    targetId,
    revisionNo,
    actor
  }));
} catch (e) {
  await c.query('rollback');
  throw e;
} finally {
  c.release();
  await pool.end();
}
