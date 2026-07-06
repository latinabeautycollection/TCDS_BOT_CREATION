import { FastifyInstance } from "fastify";
import { pool } from "../db/pool.js";

export async function labRoutes(app: FastifyInstance) {
  app.post("/api/pqp/lab/profile", async (req, reply) => {
    const b: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_test_profiles
       (profile_name, provider, proxy_label, proxy_type, expected_country, expected_timezone, user_agent)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [
        b.profileName,
        b.provider || "multilogin",
        b.proxyLabel || null,
        b.proxyType || null,
        b.expectedCountry || null,
        b.expectedTimezone || null,
        b.userAgent || null
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/lab/run/start", async (req, reply) => {
    const b: any = req.body || {};

    const result = await pool.query(
      `INSERT INTO pqp.pqp_lab_runs
       (run_name, batch_size, total_profiles, status, started_at, notes)
       VALUES ($1,$2,$3,'running',now(),$4)
       RETURNING id`,
      [
        b.runName || "owned-lab-run",
        b.batchSize || 20,
        b.totalProfiles || 0,
        b.notes || null
      ]
    );

    return reply.send({ runId: result.rows[0].id });
  });

  app.post("/api/pqp/lab/run/result", async (req, reply) => {
    const b: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_lab_run_results
       (run_id, session_id, profile_name, proxy_label,
        reached_home, reached_login, reached_product, reached_cart, reached_checkout,
        challenged, challenge_outcome, blocked, redirected, final_url,
        total_score, verdict, error, duration_ms)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18)`,
      [
        b.runId,
        b.sessionId || null,
        b.profileName || null,
        b.proxyLabel || null,
        Boolean(b.reachedHome),
        Boolean(b.reachedLogin),
        Boolean(b.reachedProduct),
        Boolean(b.reachedCart),
        Boolean(b.reachedCheckout),
        Boolean(b.challenged),
        b.challengeOutcome || null,
        Boolean(b.blocked),
        Boolean(b.redirected),
        b.finalUrl || null,
        b.totalScore || null,
        b.verdict || null,
        b.error || null,
        b.durationMs || null
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/lab/run/complete/:runId", async (req, reply) => {
    const { runId } = req.params as any;

    await pool.query(
      `UPDATE pqp.pqp_lab_runs
       SET status='completed', completed_at=now()
       WHERE id=$1`,
      [runId]
    );

    return reply.send({ ok: true });
  });

  app.get("/api/pqp/lab/summary", async (_req, reply) => {
    const result = await pool.query(`
      SELECT
        count(*)::int AS attempts,
        sum(CASE WHEN reached_checkout THEN 1 ELSE 0 END)::int AS checkout_reached,
        sum(CASE WHEN challenged THEN 1 ELSE 0 END)::int AS challenged,
        sum(CASE WHEN blocked THEN 1 ELSE 0 END)::int AS blocked,
        round(avg(total_score),2) AS avg_score
      FROM pqp.pqp_lab_run_results
    `);

    return reply.send(result.rows[0]);
  });

  app.get("/metrics", async (_req, reply) => {
    const r = await pool.query(`
      SELECT
        count(*)::int AS attempts,
        sum(CASE WHEN reached_checkout THEN 1 ELSE 0 END)::int AS checkout_reached,
        sum(CASE WHEN challenged THEN 1 ELSE 0 END)::int AS challenged,
        sum(CASE WHEN blocked THEN 1 ELSE 0 END)::int AS blocked,
        coalesce(round(avg(total_score),2),0) AS avg_score
      FROM pqp.pqp_lab_run_results
    `);

    const m = r.rows[0];

    reply.type("text/plain").send(
`# HELP pqp_lab_attempts Total lab attempts
# TYPE pqp_lab_attempts gauge
pqp_lab_attempts ${m.attempts || 0}

# HELP pqp_lab_checkout_reached Checkout reached count
# TYPE pqp_lab_checkout_reached gauge
pqp_lab_checkout_reached ${m.checkout_reached || 0}

# HELP pqp_lab_challenged Challenge count
# TYPE pqp_lab_challenged gauge
pqp_lab_challenged ${m.challenged || 0}

# HELP pqp_lab_blocked Blocked count
# TYPE pqp_lab_blocked gauge
pqp_lab_blocked ${m.blocked || 0}

# HELP pqp_lab_avg_score Average PQP score
# TYPE pqp_lab_avg_score gauge
pqp_lab_avg_score ${m.avg_score || 0}
`
    );
  });
}
