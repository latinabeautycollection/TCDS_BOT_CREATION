const fs = require("fs");
const p = "apps/pqp-api/src/routes/pqp.ts";
let s = fs.readFileSync(p, "utf8");

if (!s.includes("evaluateRealCapability")) {
  s = s.replace(
    'import { evaluateCoverage } from "../coverage/coverageService.js";',
    'import { evaluateCoverage } from "../coverage/coverageService.js";\nimport { evaluateRealCapability } from "../mismatch/mismatchEngine.js";'
  );
}

const insert = `
  app.post("/api/pqp/real-capability/snapshot", async (req, reply) => {
    const b: any = req.body || {};

    await pool.query(
      \`INSERT INTO pqp_real_capability_snapshots
       (session_id, profile_name, proxy_label, snapshot)
       VALUES ($1,$2,$3,$4)\`,
      [
        b.sessionId,
        b.profileName || null,
        b.proxyLabel || null,
        b
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/real-capability/evaluate/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;
    return reply.send(await evaluateRealCapability(sessionId));
  });

  app.get("/api/pqp/real-capability/report/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;

    const score = await pool.query(
      \`SELECT * FROM pqp_real_capability_scores WHERE session_id=$1\`,
      [sessionId]
    );

    const mismatches = await pool.query(
      \`SELECT signal_group, signal_name, linode_value, proxy_value,
              browser_value, expected_value, mismatch, severity, reason
       FROM pqp_mismatch_results
       WHERE session_id=$1
       ORDER BY
        CASE severity
          WHEN 'critical' THEN 1
          WHEN 'high' THEN 2
          WHEN 'medium' THEN 3
          ELSE 4
        END,
        signal_group,
        signal_name\`,
      [sessionId]
    );

    return reply.send({
      score: score.rows[0] || null,
      mismatches: mismatches.rows
    });
  });
`;

if (!s.includes("/api/pqp/real-capability/snapshot")) {
  const idx = s.lastIndexOf("\n}");
  s = s.slice(0, idx) + "\n" + insert + s.slice(idx);
}

fs.writeFileSync(p, s);
