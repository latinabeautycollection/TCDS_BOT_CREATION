import { pool } from "../db/pool.js";

export async function recordBaselineRun(sessionId: string, baselineType: string, label: string) {
  const score = await pool.query(
    `SELECT * FROM pqp.pqp_scores WHERE session_id=$1`,
    [sessionId]
  );

  const s = score.rows[0];
  if (!s) throw new Error("Score not found for baseline run");

  await pool.query(
    `INSERT INTO pqp.pqp_baseline_runs
     (baseline_type, label, session_id, total_score, network_score, browser_score,
      behavior_score, continuity_score, challenge_score, verdict)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
    [
      baselineType,
      label,
      sessionId,
      s.total_score,
      s.network_score,
      s.browser_score,
      s.behavior_score,
      s.continuity_score,
      s.challenge_score,
      s.verdict
    ]
  );

  return { ok: true };
}
