import { pool } from "../db/pool.js";

export async function analyzeFingerprintUniqueness(sessionId: string) {
  const fpResult = await pool.query(
    `SELECT * FROM pqp.pqp_browser_fingerprints WHERE session_id=$1 ORDER BY recorded_at DESC LIMIT 1`,
    [sessionId]
  );

  const fp = fpResult.rows[0];

  if (!fp) {
    return {
      uniquenessScore: 0,
      failReasons: ["Missing browser fingerprint"]
    };
  }

  const canvas = await pool.query(
    `SELECT count(*)::int AS count FROM pqp.pqp_browser_fingerprints
     WHERE canvas_hash=$1 AND session_id <> $2`,
    [fp.canvas_hash, sessionId]
  );

  const audio = await pool.query(
    `SELECT count(*)::int AS count FROM pqp.pqp_browser_fingerprints
     WHERE audio_hash=$1 AND session_id <> $2`,
    [fp.audio_hash, sessionId]
  );

  const webgl = await pool.query(
    `SELECT count(*)::int AS count FROM pqp.pqp_browser_fingerprints
     WHERE webgl_vendor=$1 AND webgl_renderer=$2 AND session_id <> $3`,
    [fp.webgl_vendor, fp.webgl_renderer, sessionId]
  );

  const combined = await pool.query(
    `SELECT count(*)::int AS count FROM pqp.pqp_browser_fingerprints
     WHERE canvas_hash=$1 AND audio_hash=$2 AND webgl_vendor=$3 AND webgl_renderer=$4 AND session_id <> $5`,
    [fp.canvas_hash, fp.audio_hash, fp.webgl_vendor, fp.webgl_renderer, sessionId]
  );

  const failReasons: string[] = [];
  let score = 10;

  if (canvas.rows[0].count > 5) {
    score -= 2;
    failReasons.push("Canvas hash reused across many sessions");
  }

  if (audio.rows[0].count > 5) {
    score -= 2;
    failReasons.push("Audio hash reused across many sessions");
  }

  if (webgl.rows[0].count > 20) {
    score -= 2;
    failReasons.push("WebGL signature highly clustered");
  }

  if (combined.rows[0].count > 2) {
    score -= 4;
    failReasons.push("Combined fingerprint reused");
  }

  await pool.query(
    `INSERT INTO pqp.pqp_fingerprint_uniqueness
     (session_id, canvas_seen_count, audio_seen_count, webgl_seen_count, combined_seen_count, uniqueness_score, fail_reasons)
     VALUES ($1,$2,$3,$4,$5,$6,$7)`,
    [
      sessionId,
      canvas.rows[0].count,
      audio.rows[0].count,
      webgl.rows[0].count,
      combined.rows[0].count,
      Math.max(0, score),
      JSON.stringify(failReasons)
    ]
  );

  return {
    uniquenessScore: Math.max(0, score),
    failReasons
  };
}
