import fs from "fs";
import { randomUUID } from "crypto";
import { pool } from "../apps/pqp-api/src/db/pool.js";

const auditFile = process.env.MLX_AUDIT_FILE || "/srv/pqp/reports/mlx/mlx-fingerprint-config-audit.json";

async function ensureTable() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS pqp.pqp_mlx_fingerprint_config_audits (
      id BIGSERIAL PRIMARY KEY,
      report_run_id UUID NOT NULL,
      profile_name TEXT NOT NULL,
      profile_id TEXT NOT NULL,
      timezone_masking TEXT,
      localization_masking TEXT,
      geolocation_masking TEXT,
      canvas_noise TEXT,
      graphics_masking TEXT,
      graphics_noise TEXT,
      audio_masking TEXT,
      webgl_vendor TEXT,
      webgl_renderer TEXT,
      timezone_zone TEXT,
      locale TEXT,
      languages TEXT,
      geolocation_latitude DOUBLE PRECISION,
      geolocation_longitude DOUBLE PRECISION,
      webgl_noise_ok BOOLEAN NOT NULL DEFAULT false,
      canvas_noise_ok BOOLEAN NOT NULL DEFAULT false,
      timezone_customized BOOLEAN NOT NULL DEFAULT false,
      localization_customized BOOLEAN NOT NULL DEFAULT false,
      geolocation_customized BOOLEAN NOT NULL DEFAULT false,
      status TEXT NOT NULL,
      reasons JSONB NOT NULL DEFAULT '[]'::jsonb,
      raw JSONB NOT NULL DEFAULT '{}'::jsonb,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE INDEX IF NOT EXISTS idx_pqp_mlx_fp_audit_profile
      ON pqp.pqp_mlx_fingerprint_config_audits(profile_name);

    CREATE INDEX IF NOT EXISTS idx_pqp_mlx_fp_audit_run
      ON pqp.pqp_mlx_fingerprint_config_audits(report_run_id);

    CREATE INDEX IF NOT EXISTS idx_pqp_mlx_fp_audit_created
      ON pqp.pqp_mlx_fingerprint_config_audits(created_at DESC);
  `);
}

async function main() {
  await ensureTable();

  if (!fs.existsSync(auditFile)) {
    throw new Error(`Missing audit file: ${auditFile}`);
  }

  const profiles = JSON.parse(fs.readFileSync(auditFile, "utf8"));
  const reportRunId = randomUUID();
  const rows = [];

  for (const item of profiles) {
    const flags = item.parameters?.flags || {};
    const fp = item.parameters?.fingerprint || {};
    const graphic = fp.graphic || {};

    const reasons = [];

    const webglNoiseOk = ["natural", "custom", "mask"].includes(String(flags.graphics_noise || ""));
    const canvasNoiseOk = String(flags.canvas_noise || "") !== "disabled";
    const timezoneCustomized = Boolean(fp.timezone?.zone);
    const localizationCustomized = Boolean(fp.localization?.locale || fp.localization?.languages);
    const geolocationCustomized = fp.geolocation?.latitude !== undefined && fp.geolocation?.longitude !== undefined;

    if (!canvasNoiseOk) {
      reasons.push({ severity: "high", reason: "Canvas noise is disabled" });
    }

    if (!webglNoiseOk) {
      reasons.push({ severity: "high", reason: "WebGL/graphics noise is not configured" });
    }

    if (!timezoneCustomized) {
      reasons.push({ severity: "medium", reason: "Timezone is not explicitly configured" });
    }

    if (!localizationCustomized) {
      reasons.push({ severity: "medium", reason: "Localization/language is not explicitly configured" });
    }

    if (!geolocationCustomized) {
      reasons.push({ severity: "medium", reason: "Geolocation is not explicitly configured" });
    }

    const status = reasons.some(r => r.severity === "high")
      ? "warning"
      : reasons.length
        ? "review"
        : "pass";

    await pool.query(`
      INSERT INTO pqp.pqp_mlx_fingerprint_config_audits (
        report_run_id, profile_name, profile_id,
        timezone_masking, localization_masking, geolocation_masking,
        canvas_noise, graphics_masking, graphics_noise, audio_masking,
        webgl_vendor, webgl_renderer, timezone_zone, locale, languages,
        geolocation_latitude, geolocation_longitude,
        webgl_noise_ok, canvas_noise_ok, timezone_customized,
        localization_customized, geolocation_customized,
        status, reasons, raw
      ) VALUES (
        $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,
        $16,$17,$18,$19,$20,$21,$22,$23,$24,$25
      )
    `, [
      reportRunId,
      item.name,
      item.profileId,
      flags.timezone_masking || null,
      flags.localization_masking || null,
      flags.geolocation_masking || null,
      flags.canvas_noise || null,
      flags.graphics_masking || null,
      flags.graphics_noise || null,
      flags.audio_masking || null,
      graphic.vendor || null,
      graphic.renderer || null,
      fp.timezone?.zone || null,
      fp.localization?.locale || null,
      fp.localization?.languages || null,
      fp.geolocation?.latitude ?? null,
      fp.geolocation?.longitude ?? null,
      webglNoiseOk,
      canvasNoiseOk,
      timezoneCustomized,
      localizationCustomized,
      geolocationCustomized,
      status,
      JSON.stringify(reasons),
      JSON.stringify(item)
    ]);

    rows.push({
      profileName: item.name,
      profileId: item.profileId,
      canvasNoise: flags.canvas_noise || null,
      graphicsMasking: flags.graphics_masking || null,
      graphicsNoise: flags.graphics_noise || null,
      timezoneZone: fp.timezone?.zone || null,
      locale: fp.localization?.locale || null,
      geolocation: fp.geolocation || null,
      status,
      reasons
    });
  }

  console.log(JSON.stringify({
    reportRunId,
    totalRows: rows.length,
    pass: rows.filter(r => r.status === "pass").length,
    review: rows.filter(r => r.status === "review").length,
    warning: rows.filter(r => r.status === "warning").length,
    rows: rows.slice(0, 50)
  }, null, 2));

  await pool.end();
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
