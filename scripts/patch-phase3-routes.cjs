const fs = require("fs");
const path = "apps/pqp-api/src/routes/pqp.ts";
let s = fs.readFileSync(path, "utf8");

if (!s.includes('paidIpIntel')) {
  s = s.replace(
    'import { writeEvidenceReport } from "../reports/evidenceReport.js";',
    'import { writeEvidenceReport } from "../reports/evidenceReport.js";\nimport { paidIpIntel } from "../integrations/ipIntel.js";\nimport { sendPqpAlert } from "../alerts/alertService.js";\nimport { recordBaselineRun } from "../baselines/baselineService.js";'
  );
}

const insert = `
  app.post("/api/pqp/edge-log-ingest", async (req, reply) => {
    const body: any = req.body || {};

    await pool.query(
      \`INSERT INTO pqp_edge_log_ingest
       (session_id, source, request_id, ip_address, ja3_hash, ja4_hash,
        tls_version, alpn, http_version, header_order, raw)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)\`,
      [
        body.sessionId,
        body.source || "unknown-edge",
        body.requestId || null,
        body.ipAddress || null,
        body.ja3Hash || null,
        body.ja4Hash || null,
        body.tlsVersion || null,
        body.alpn || null,
        body.httpVersion || null,
        body.headerOrder || [],
        body.raw || {}
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/paid-ip-intel/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;

    const result = await pool.query(
      \`SELECT ip_address FROM pqp_sessions WHERE id=$1\`,
      [sessionId]
    );

    const ip = String(result.rows[0]?.ip_address || "");
    const intel = await paidIpIntel(ip);

    await pool.query(
      \`INSERT INTO pqp_ip_reputation
       (session_id, ip_address, asn, org, country_code, ip_type, reputation_score, risk_reasons)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8)\`,
      [
        sessionId,
        ip || null,
        intel.asn || null,
        intel.org || null,
        intel.countryCode || null,
        intel.ipType,
        intel.reputationScore,
        JSON.stringify(intel.riskReasons)
      ]
    );

    return reply.send(intel);
  });

  app.post("/api/pqp/alert/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;
    const body: any = req.body || {};
    return reply.send(await sendPqpAlert(
      sessionId,
      body.severity || "medium",
      body.message || "PQP alert"
    ));
  });

  app.post("/api/pqp/baseline/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;
    const body: any = req.body || {};
    return reply.send(await recordBaselineRun(
      sessionId,
      body.baselineType || "unknown",
      body.label || "unnamed-run"
    ));
  });

  app.get("/api/pqp/baselines/summary", async (_req, reply) => {
    const result = await pool.query(
      \`SELECT * FROM pqp_longitudinal_summary ORDER BY baseline_type\`
    );
    return reply.send(result.rows);
  });
`;

if (!s.includes('/api/pqp/edge-log-ingest')) {
  const idx = s.lastIndexOf("\n}");
  s = s.slice(0, idx) + "\n" + insert + s.slice(idx);
}

fs.writeFileSync(path, s);
