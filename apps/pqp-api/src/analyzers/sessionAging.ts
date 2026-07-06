import { pool } from "../db/pool.js";

export async function analyzeSessionAging(sessionId: string) {
  const result = await pool.query(
    `SELECT min(recorded_at) AS first_seen, max(recorded_at) AS last_seen
     FROM pqp.pqp_browser_fingerprints WHERE session_id=$1`,
    [sessionId]
  );

  const first = result.rows[0]?.first_seen ? new Date(result.rows[0].first_seen) : null;
  const last = result.rows[0]?.last_seen ? new Date(result.rows[0].last_seen) : null;

  let ageMinutes = 0;
  if (first && last) {
    ageMinutes = Math.round((last.getTime() - first.getTime()) / 60000);
  }

  const failReasons: string[] = [];
  let score = 10;

  if (!first) {
    score = 0;
    failReasons.push("No session aging evidence found");
  }

  if (ageMinutes === 0) {
    score -= 3;
    failReasons.push("Session appears brand new");
  }

  await pool.query(
    `INSERT INTO pqp.pqp_session_aging
     (session_id, first_seen_at, last_seen_at, age_minutes, aging_score, fail_reasons)
     VALUES ($1,$2,$3,$4,$5,$6)`,
    [
      sessionId,
      first,
      last,
      ageMinutes,
      Math.max(0, score),
      JSON.stringify(failReasons)
    ]
  );

  return {
    agingScore: Math.max(0, score),
    failReasons
  };
}
