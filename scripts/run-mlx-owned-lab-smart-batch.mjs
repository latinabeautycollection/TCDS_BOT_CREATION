import fs from "fs";
import { execFileSync } from "child_process";
import puppeteer from "puppeteer-core";
import { pool } from "../dist/apps/pqp-api/src/db/pool.js";

const CLI_DIR = "/home/mloginops/mlx/deps/cli";
const XCLI = `${CLI_DIR}/xcli`;
const MAP = "/srv/pqp/reports/mlx/mlx-profile-map.tsv";
const TMP_DIR = "/home/mloginops/tmp/mlx-batch";
const FAILED_FILE = `${TMP_DIR}/failed-profiles.json`;
const BASE_URL = process.env.PQP_LAB_URL || "http://23.239.12.166:8089/pqp/pqp/labs/owned-checkout-lab.html";
const LIMIT = Number(process.env.LIMIT || 10);
const START = Number(process.env.START || 0);

fs.mkdirSync(TMP_DIR, { recursive: true });

const allProfiles = fs.readFileSync(MAP, "utf8")
  .trim()
  .split("\n")
  .map(line => {
    const [name, id] = line.split("\t");
    return { name, id };
  });

const completedQ = await pool.query(`
  SELECT DISTINCT profile_name
  FROM (
    SELECT profile_name FROM pqp.pqp_real_capability_snapshots
    WHERE profile_name ~ '^ML-US-[0-9]{3}$'
    UNION
    SELECT profile_name FROM pqp.pqp_phase4_score_history
    WHERE profile_name ~ '^ML-US-[0-9]{3}$'
  ) x
`);

const completed = new Set(completedQ.rows.map(r => r.profile_name));

let failedMap = new Map();
if (fs.existsSync(FAILED_FILE)) {
  for (const f of JSON.parse(fs.readFileSync(FAILED_FILE, "utf8"))) {
    if (!completed.has(f.name)) failedMap.set(f.name, f);
  }
}

const retryProfiles = [...failedMap.values()]
  .map(f => allProfiles.find(p => p.name === f.name) || f)
  .filter(p => p?.name && p?.id && !completed.has(p.name));

const freshProfiles = allProfiles
  .slice(START)
  .filter(p => !completed.has(p.name))
  .filter(p => !failedMap.has(p.name));

const seen = new Set();
const toRun = [...retryProfiles, ...freshProfiles]
  .filter(p => {
    if (seen.has(p.name)) return false;
    seen.add(p.name);
    return true;
  })
  .slice(0, LIMIT);

console.log(JSON.stringify({
  start: START,
  limit: LIMIT,
  alreadyCaptured: completed.size,
  retryQueue: retryProfiles.length,
  selected: toRun.map(p => p.name)
}, null, 2));

function runXcli(args) {
  return execFileSync(XCLI, args, {
    cwd: CLI_DIR,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  });
}

function readProfile(name, id) {
  const auditFile = `/tmp/mlx-audit/${name}.json`;
  if (fs.existsSync(auditFile)) return JSON.parse(fs.readFileSync(auditFile, "utf8"));

  const dumpScript = `${TMP_DIR}/mlx-dump-${name}.sh`;
  const outFile = `${TMP_DIR}/mlx-profile-${name}-batch.json`;

  fs.writeFileSync(dumpScript, `#!/usr/bin/env bash
set -euo pipefail
cp "$1" "${outFile}"
exit 0
`);
  fs.chmodSync(dumpScript, 0o755);

  execFileSync(XCLI, ["profile-update", "--profile-id", id], {
    cwd: CLI_DIR,
    encoding: "utf8",
    env: { ...process.env, XEDITOR: dumpScript, EDITOR: dumpScript, VISUAL: dumpScript },
    stdio: ["ignore", "pipe", "pipe"]
  });

  return JSON.parse(fs.readFileSync(outFile, "utf8"));
}

async function waitForDebugPort(port, timeoutMs = 30000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (r.ok) return;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  throw new Error(`Debug port ${port} was not ready`);
}

async function runProfile({ name, id }) {
  let browser;

  try {
    console.log(`\nSTART ${name} ${id}`);

    const profile = readProfile(name, id);
    const proxy = profile.parameters?.proxy || {};

    try { runXcli(["profile-stop", "--profile-id", id]); } catch {}

    const startOut = runXcli(["profile-start", "--profile-id", id, "--automation", "puppeteer"]);
    console.log(startOut.trim());

    const match = startOut.match(/port:\s*(\d+)/i);
    if (!match) throw new Error("Could not parse browser port");

    const port = match[1];
    await waitForDebugPort(port);

    browser = await puppeteer.connect({ browserURL: `http://127.0.0.1:${port}` });
    const page = await browser.newPage();

    if (proxy.username && proxy.password) {
      await page.authenticate({ username: proxy.username, password: proxy.password });
    }

    const url = `${BASE_URL}?profileName=${encodeURIComponent(name)}&runId=batch-${Date.now()}`;
    await page.goto(url, { waitUntil: "networkidle2", timeout: 120000 });

    await page.evaluate(async () => {
      await window.runFullPqpCapture();
      await window.runAnalyze();
    });

    const sessionId = await page.evaluate(() => window.sessionId);
    console.log(`DONE ${name}: ${sessionId}`);

    failedMap.delete(name);
    completed.add(name);
  } catch (err) {
    const message = err.message || String(err);
    console.error(`FAILED ${name}: ${message}`);
    failedMap.set(name, { name, id, reason: message, failedAt: new Date().toISOString() });
  } finally {
    try { if (browser) await browser.disconnect(); } catch {}
    try {
      runXcli(["profile-stop", "--profile-id", id]);
      console.log(`STOPPED ${name}`);
    } catch (err) {
      console.error(`STOP FAILED ${name}:`, err.message || err);
    }
  }
}

for (const profile of toRun) {
  await runProfile(profile);
  await new Promise(resolve => setTimeout(resolve, 5000));
}

fs.writeFileSync(FAILED_FILE, JSON.stringify([...failedMap.values()], null, 2));
await pool.end();

console.log(JSON.stringify({
  batchComplete: true,
  capturedTotalKnown: completed.size,
  failedQueue: failedMap.size,
  failedFile: FAILED_FILE
}, null, 2));
