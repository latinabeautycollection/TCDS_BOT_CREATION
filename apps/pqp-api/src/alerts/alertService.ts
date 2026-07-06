import { pool } from "../db/pool.js";

export async function sendPqpAlert(sessionId: string, severity: string, message: string) {
  const webhook = process.env.PQP_ALERT_WEBHOOK_URL;
  const destination = webhook ? "webhook" : "database-only";

  let delivered = false;

  if (webhook) {
    const res = await fetch(webhook, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        text: `[PQP ${severity.toUpperCase()}] ${message}`,
        sessionId
      })
    });

    delivered = res.ok;
  }

  await pool.query(
    `INSERT INTO pqp.pqp_alerts
     (session_id, alert_type, severity, message, destination, delivered)
     VALUES ($1,$2,$3,$4,$5,$6)`,
    [sessionId, "pqp_score_alert", severity, message, destination, delivered]
  );

  return { delivered, destination };
}
