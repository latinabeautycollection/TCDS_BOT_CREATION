import { randomUUID } from "node:crypto";
import { pool } from "../db/pool.js";

async function generateQaReport() {
  const reportRunId = randomUUID();

  const rows = await pool.query(`
    WITH latest_real AS (
      SELECT DISTINCT ON (session_id)
        session_id,
        profile_name,
        proxy_label,
        final_capability_score,
        critical_count,
        high_count,
        medium_count,
        low_count,
        verdict,
        created_at
      FROM pqp.pqp_real_capability_scores
      ORDER BY session_id, created_at DESC
    ),
    latest_phase4 AS (
      SELECT DISTINCT ON (session_id)
        session_id,
        profile_name,
        network_score,
        fingerprint_score,
        behavior_score,
        challenge_score,
        proxy_score,
        population_score,
        aging_score,
        profile_capability_score,
        verdict,
        created_at
      FROM pqp.pqp_phase4_score_history
      ORDER BY session_id, created_at DESC
    ),
    latest_ip AS (
      SELECT DISTINCT ON (session_id)
        session_id,
        ip_address::text AS proxy_ip,
        asn::text AS proxy_asn,
        org AS proxy_isp,
        ip_type AS proxy_type,
        country_code AS proxy_country,
        reputation_score AS ip_reputation_score,
        risk_reasons AS ip_risk_reasons,
        recorded_at
      FROM pqp.pqp_ip_reputation
      ORDER BY session_id, recorded_at DESC
    ),
    latest_snapshot AS (
      SELECT DISTINCT ON (session_id)
        session_id,
        profile_name,
        proxy_label,
        snapshot,
        created_at
      FROM pqp.pqp_real_capability_snapshots
      ORDER BY session_id, created_at DESC
    ),
    mismatch_summary AS (
      SELECT
        session_id,
        jsonb_agg(
          jsonb_build_object(
            'signalGroup', signal_group,
            'signalName', signal_name,
            'severity', severity,
            'reason', reason
          )
          ORDER BY
            CASE severity
              WHEN 'critical' THEN 1
              WHEN 'high' THEN 2
              WHEN 'medium' THEN 3
              ELSE 4
            END,
            signal_group,
            signal_name
        ) FILTER (WHERE mismatch = true) AS fail_reasons
      FROM pqp.pqp_mismatch_results
      GROUP BY session_id
    ),
    combined AS (
      SELECT
        COALESCE(r.session_id, p.session_id, i.session_id, s.session_id) AS session_id,
        COALESCE(r.profile_name, p.profile_name, s.profile_name) AS profile_name,
        COALESCE(r.proxy_label, s.proxy_label) AS proxy_label,
        COALESCE(i.proxy_ip, s.snapshot->'proxy'->>'ip', s.snapshot->>'proxyLabel') AS proxy_ip,
        COALESCE(i.proxy_asn, s.snapshot->'proxy'->>'asn') AS proxy_asn,
        COALESCE(i.proxy_isp, s.snapshot->'proxy'->>'isp') AS proxy_isp,
        COALESCE(i.proxy_type, s.snapshot->'proxy'->>'type') AS proxy_type,
        COALESCE(i.proxy_country, s.snapshot->'proxy'->>'country') AS proxy_country,
        s.snapshot->'proxy'->>'region' AS proxy_region,
        s.snapshot->'proxy'->>'city' AS proxy_city,
        i.ip_reputation_score,
        COALESCE(i.ip_risk_reasons, '[]'::jsonb) AS ip_risk_reasons,
        r.final_capability_score AS real_capability_score,
        p.profile_capability_score AS phase4_capability_score,
        p.network_score,
        p.fingerprint_score,
        p.behavior_score,
        p.challenge_score,
        p.proxy_score,
        p.population_score,
        p.aging_score,
        COALESCE(r.critical_count, 0) AS critical_count,
        COALESCE(r.high_count, 0) AS high_count,
        COALESCE(r.medium_count, 0) AS medium_count,
        COALESCE(r.low_count, 0) AS low_count,
        COALESCE(p.verdict, r.verdict) AS verdict,
        COALESCE(m.fail_reasons, '[]'::jsonb) AS top_fail_reasons,
        jsonb_build_object(
          'realCapabilityCreatedAt', r.created_at,
          'phase4CreatedAt', p.created_at,
          'ipRecordedAt', i.recorded_at,
          'snapshotCreatedAt', s.created_at
        ) AS source
      FROM latest_real r
      FULL OUTER JOIN latest_phase4 p ON p.session_id = r.session_id
      FULL OUTER JOIN latest_ip i ON i.session_id = COALESCE(r.session_id, p.session_id)
      FULL OUTER JOIN latest_snapshot s ON s.session_id = COALESCE(r.session_id, p.session_id, i.session_id)
      LEFT JOIN mismatch_summary m ON m.session_id = COALESCE(r.session_id, p.session_id, i.session_id, s.session_id)
    )
    INSERT INTO pqp.pqp_qa_profile_reports (
      report_run_id,
      session_id,
      profile_name,
      proxy_label,
      proxy_ip,
      proxy_asn,
      proxy_isp,
      proxy_type,
      proxy_country,
      proxy_region,
      proxy_city,
      ip_reputation_score,
      ip_risk_reasons,
      real_capability_score,
      phase4_capability_score,
      network_score,
      fingerprint_score,
      behavior_score,
      challenge_score,
      proxy_score,
      population_score,
      aging_score,
      critical_count,
      high_count,
      medium_count,
      low_count,
      verdict,
      top_fail_reasons,
      source
    )
    SELECT
      $1,
      session_id,
      profile_name,
      proxy_label,
      proxy_ip,
      proxy_asn,
      proxy_isp,
      proxy_type,
      proxy_country,
      proxy_region,
      proxy_city,
      ip_reputation_score,
      ip_risk_reasons,
      real_capability_score,
      phase4_capability_score,
      network_score,
      fingerprint_score,
      behavior_score,
      challenge_score,
      proxy_score,
      population_score,
      aging_score,
      critical_count,
      high_count,
      medium_count,
      low_count,
      verdict,
      top_fail_reasons,
      source
    FROM combined
    WHERE session_id IS NOT NULL
      AND (
        real_capability_score IS NOT NULL
        OR phase4_capability_score IS NOT NULL
        OR critical_count > 0
        OR high_count > 0
        OR medium_count > 0
        OR low_count > 0
      )
      AND COALESCE(proxy_ip, '') NOT LIKE '127.%'
    RETURNING *
  `, [reportRunId]);

  const summary = {
    reportRunId,
    totalRows: rows.rowCount,
    generatedAt: new Date().toISOString(),
    verdicts: rows.rows.reduce((acc: any, row: any) => {
      const key = row.verdict || "unknown";
      acc[key] = (acc[key] || 0) + 1;
      return acc;
    }, {})
  };

  return {
    ok: true,
    summary,
    rows: rows.rows
  };
}

async function getLatestQaReport(limit = 100) {
  const latestRun = await pool.query(`
    SELECT report_run_id
    FROM pqp.pqp_qa_profile_reports
    ORDER BY generated_at DESC
    LIMIT 1
  `);

  const reportRunId = latestRun.rows[0]?.report_run_id;
  if (!reportRunId) {
    return {
      ok: true,
      summary: { totalRows: 0 },
      rows: []
    };
  }

  const rows = await pool.query(
    `SELECT *
     FROM pqp.pqp_qa_profile_reports
     WHERE report_run_id=$1
     ORDER BY
      CASE verdict
        WHEN 'fail' THEN 1
        WHEN 'weak' THEN 2
        WHEN 'usable_with_warnings' THEN 3
        WHEN 'strong' THEN 4
        ELSE 5
      END,
      critical_count DESC,
      high_count DESC,
      phase4_capability_score ASC NULLS LAST,
      real_capability_score ASC NULLS LAST
     LIMIT $2`,
    [reportRunId, limit]
  );

  return {
    ok: true,
    summary: {
      reportRunId,
      totalRows: rows.rowCount,
      generatedAt: rows.rows[0]?.generated_at || null
    },
    rows: rows.rows
  };
}

export async function registerPqpQaReportRoutes(app: any) {
  app.post("/api/pqp/qa/report/generate", async (_req: any, reply: any) => {
    return reply.send(await generateQaReport());
  });

  app.get("/api/pqp/qa/report/latest", async (req: any, reply: any) => {
    const limit = Math.min(Number((req.query as any)?.limit || 20), 100);

    const summaryQ = await pool.query(
      `SELECT report_run_id, COUNT(*)::int AS total_rows, MAX(generated_at) AS generated_at
       FROM pqp.pqp_qa_profile_reports
       WHERE report_run_id = (
        SELECT report_run_id
        FROM pqp.pqp_qa_profile_reports
        ORDER BY generated_at DESC
        LIMIT 1
       )
       GROUP BY report_run_id`
    );

    const reportRunId = summaryQ.rows[0]?.report_run_id || null;

    const rowsQ = await pool.query(
      `SELECT
        qr.*,
        COALESCE(edge.edge_http_event_count, 0) AS edge_http_event_count,
        edge.latest_ja3,
        edge.latest_ja4,
        edge.latest_tls_version,
        edge.latest_http_version,
        COALESCE(tx.transaction_event_count, 0) AS transaction_event_count,
        tx.latest_transaction_event,
        tx.latest_transaction_page,
        tx.latest_transaction_duration_ms,
        aging.cookie_age_ms,
        aging.local_storage_age_ms,
        aging.indexeddb_age_ms,
        aging.service_worker_age_ms,
        aging.cache_age_ms
       FROM pqp.pqp_qa_profile_reports qr
       LEFT JOIN LATERAL (
        SELECT
          COUNT(*)::int AS edge_http_event_count,
          (ARRAY_AGG(ja3 ORDER BY created_at DESC))[1] AS latest_ja3,
          (ARRAY_AGG(ja4 ORDER BY created_at DESC))[1] AS latest_ja4,
          (ARRAY_AGG(tls_version ORDER BY created_at DESC))[1] AS latest_tls_version,
          (ARRAY_AGG(http_version ORDER BY created_at DESC))[1] AS latest_http_version
        FROM pqp.pqp_edge_http_events e
        WHERE e.profile_name = qr.profile_name
       ) edge ON true
       LEFT JOIN LATERAL (
        SELECT
          COUNT(*)::int AS transaction_event_count,
          (ARRAY_AGG(event_type ORDER BY created_at DESC))[1] AS latest_transaction_event,
          (ARRAY_AGG(page ORDER BY created_at DESC))[1] AS latest_transaction_page,
          (ARRAY_AGG(duration_ms ORDER BY created_at DESC))[1] AS latest_transaction_duration_ms
        FROM pqp.pqp_transaction_events t
        WHERE t.profile_name = qr.profile_name
       ) tx ON true
       LEFT JOIN LATERAL (
        SELECT cookie_age_ms, local_storage_age_ms, indexeddb_age_ms,
               service_worker_age_ms, cache_age_ms
        FROM pqp.pqp_profile_aging_events a
        WHERE a.profile_name = qr.profile_name
        ORDER BY created_at DESC
        LIMIT 1
       ) aging ON true
       WHERE qr.report_run_id = $1
       ORDER BY qr.generated_at DESC, qr.profile_name
       LIMIT $2`,
      [reportRunId, limit]
    );

    return reply.send({
      summary: summaryQ.rows[0] || null,
      rows: rowsQ.rows
    });
  });
}
