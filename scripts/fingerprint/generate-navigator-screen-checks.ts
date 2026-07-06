import crypto from "node:crypto";
import { pool } from "../../apps/pqp-api/src/db/pool.js";

const reportRunId = crypto.randomUUID();

function intOrNull(v: any) {
  const n = Number(v);
  return Number.isFinite(n) ? Math.trunc(n) : null;
}

function numOrNull(v: any) {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function boolOrNull(v: any) {
  return typeof v === "boolean" ? v : null;
}

function pickNavigator(snapshot: any) {
  const extra = snapshot?.extraBrowserSignals || {};
  return {
    ...(extra?.navigatorAttributes || {}),
    ...(extra?.navigator || {}),
    ...(snapshot?.navigator || {})
  };
}

function pickScreen(snapshot: any) {
  const extra = snapshot?.extraBrowserSignals || {};
  return {
    ...(extra?.screen || {}),
    ...(snapshot?.screen || {}),
    window: {
      ...(extra?.window || {}),
      ...(snapshot?.window || {})
    },
    touchSupport: snapshot?.touchSupport || snapshot?.screen?.touchSupport || extra?.touchSupport || extra?.touch || null
  };
}

const q = await pool.query(`
  SELECT DISTINCT ON (profile_name)
    session_id,
    profile_name,
    snapshot,
    created_at
  FROM pqp.pqp_real_capability_snapshots
  WHERE profile_name ~ '^ML-US-[0-9]{3}$'
  ORDER BY profile_name, created_at DESC
`);

for (const row of q.rows) {
  const snapshot = row.snapshot || {};
  const nav = pickNavigator(snapshot);
  const screen = pickScreen(snapshot);

  const navReasons: any[] = [];
  const screenReasons: any[] = [];

  const userAgent = nav.userAgent ?? nav.user_agent ?? null;
  const language = nav.language ?? null;
  const languages = nav.languages ?? null;

  if (!userAgent) navReasons.push({ severity: "medium", reason: "navigator.userAgent missing" });
  if (!language) navReasons.push({ severity: "medium", reason: "navigator.language missing" });
  if (!languages) navReasons.push({ severity: "medium", reason: "navigator.languages missing" });
  if (!nav.plugins && nav.pluginsCount == null) navReasons.push({ severity: "low", reason: "navigator.plugins missing" });
  if (!nav.mimeTypes && nav.mimeTypesCount == null) navReasons.push({ severity: "low", reason: "navigator.mimeTypes missing" });

  const navStatus = navReasons.length ? "warning" : "ok";

  const screenWidth = intOrNull(screen.width ?? screen.screenWidth);
  const screenHeight = intOrNull(screen.height ?? screen.screenHeight);
  const innerWidth = intOrNull(screen.window?.innerWidth ?? screen.innerWidth);
  const innerHeight = intOrNull(screen.window?.innerHeight ?? screen.innerHeight);
  const dpr = numOrNull(screen.devicePixelRatio ?? screen.pixelRatio);
  const orientation = screen.orientation ?? null;
  const touchSupport = screen.touchSupport ?? null;

  if (screenWidth == null || screenHeight == null) {
    screenReasons.push({ severity: "medium", reason: "screen.width/height missing" });
  }
  if (innerWidth == null || innerHeight == null) {
    screenReasons.push({ severity: "medium", reason: "window.innerWidth/innerHeight missing" });
  }
  if (dpr == null) {
    screenReasons.push({ severity: "medium", reason: "devicePixelRatio missing" });
  }
  if (!orientation) {
    screenReasons.push({ severity: "low", reason: "screen.orientation missing" });
  }
  if (!touchSupport) {
    screenReasons.push({ severity: "low", reason: "touchSupport missing" });
  }

  const screenStatus = screenReasons.length ? "warning" : "ok";

  await pool.query(`
    INSERT INTO pqp.pqp_navigator_fingerprint_checks (
      report_run_id, session_id, profile_name,
      user_agent, user_agent_data, platform, vendor, webdriver,
      language, languages, cookie_enabled, hardware_concurrency,
      device_memory, max_touch_points, pdf_viewer_enabled,
      plugins, mime_types, status, reasons, raw
    )
    VALUES (
      $1,$2,$3,$4,$5::jsonb,$6,$7,$8,$9,$10::jsonb,$11,$12,$13,$14,$15,$16::jsonb,$17::jsonb,$18,$19::jsonb,$20::jsonb
    )
  `, [
    reportRunId,
    row.session_id,
    row.profile_name,
    userAgent,
    JSON.stringify(nav.userAgentData ?? nav.user_agent_data ?? null),
    nav.platform ?? null,
    nav.vendor ?? null,
    boolOrNull(nav.webdriver),
    language,
    JSON.stringify(languages ?? null),
    boolOrNull(nav.cookieEnabled ?? nav.cookie_enabled),
    intOrNull(nav.hardwareConcurrency ?? nav.hardware_concurrency),
    numOrNull(nav.deviceMemory ?? nav.device_memory),
    intOrNull(nav.maxTouchPoints ?? nav.max_touch_points),
    boolOrNull(nav.pdfViewerEnabled ?? nav.pdf_viewer_enabled),
    JSON.stringify(nav.plugins ?? null),
    JSON.stringify(nav.mimeTypes ?? nav.mime_types ?? null),
    navStatus,
    JSON.stringify(navReasons),
    JSON.stringify(nav)
  ]);

  await pool.query(`
    INSERT INTO pqp.pqp_screen_fingerprint_checks (
      report_run_id, session_id, profile_name,
      screen_width, screen_height, screen_avail_width, screen_avail_height,
      screen_color_depth, screen_pixel_depth,
      window_inner_width, window_inner_height, window_outer_width, window_outer_height,
      device_pixel_ratio, orientation, touch_support,
      status, reasons, raw
    )
    VALUES (
      $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15::jsonb,$16::jsonb,$17,$18::jsonb,$19::jsonb
    )
  `, [
    reportRunId,
    row.session_id,
    row.profile_name,
    screenWidth,
    screenHeight,
    intOrNull(screen.availWidth ?? screen.availableWidth),
    intOrNull(screen.availHeight ?? screen.availableHeight),
    intOrNull(screen.colorDepth),
    intOrNull(screen.pixelDepth),
    innerWidth,
    innerHeight,
    intOrNull(screen.window?.outerWidth ?? screen.outerWidth),
    intOrNull(screen.window?.outerHeight ?? screen.outerHeight),
    dpr,
    JSON.stringify(orientation),
    JSON.stringify(touchSupport),
    screenStatus,
    JSON.stringify(screenReasons),
    JSON.stringify(screen)
  ]);
}

const navSummary = await pool.query(`
  SELECT status, count(*)::int AS rows
  FROM pqp.pqp_navigator_fingerprint_checks
  WHERE report_run_id=$1
  GROUP BY status
  ORDER BY status
`, [reportRunId]);

const screenSummary = await pool.query(`
  SELECT status, count(*)::int AS rows
  FROM pqp.pqp_screen_fingerprint_checks
  WHERE report_run_id=$1
  GROUP BY status
  ORDER BY status
`, [reportRunId]);

console.log(JSON.stringify({
  reportRunId,
  profiles: q.rowCount,
  navigator: navSummary.rows,
  screen: screenSummary.rows
}, null, 2));

await pool.end();
