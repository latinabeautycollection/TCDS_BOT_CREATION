import fs from "fs";
import { execFileSync } from "child_process";
import puppeteer from "puppeteer-core";

const CLI_DIR = "/home/mloginops/mlx/deps/cli";
const XCLI = `${CLI_DIR}/xcli`;
const MAP = "/srv/pqp/reports/mlx/mlx-profile-map.tsv";
const BASE_URL = process.env.PQP_LAB_URL || "http://23.239.12.166:8089/pqp/pqp/labs/owned-checkout-lab.html";
const LIMIT = Number(process.env.LIMIT || 10);
const START = Number(process.env.START || 0);

const profiles = fs.readFileSync(MAP, "utf8")
  .trim()
  .split("\n")
  .map(line => {
    const [name, id] = line.split("\t");
    return { name, id };
  })
  .slice(START, START + LIMIT);

function runXcli(args) {
  return execFileSync(XCLI, args, {
    cwd: CLI_DIR,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  });
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
  throw new Error(`Debug port ${port} was not ready after ${timeoutMs}ms`);
}

function dumpProfile(profileId, name) {
  const dumpScript = `/home/mloginops/tmp/mlx-batch/mlx-dump-${name}.sh`;
  const outFile = `/home/mloginops/tmp/mlx-batch/mlx-profile-${name}-batch.json`;

  fs.writeFileSync(dumpScript, `#!/usr/bin/env bash
set -euo pipefail
cp "$1" "${outFile}"
exit 0
`);
  fs.chmodSync(dumpScript, 0o755);

  execFileSync(XCLI, ["profile-update", "--profile-id", profileId], {
    cwd: CLI_DIR,
    encoding: "utf8",
    env: {
      ...process.env,
      XEDITOR: dumpScript,
      EDITOR: dumpScript,
      VISUAL: dumpScript
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  return JSON.parse(fs.readFileSync(outFile, "utf8"));
}

async function runProfile({ name, id }) {
  let port = null;

  try {
    console.log(`\nSTART ${name} ${id}`);

    const profile = dumpProfile(id, name);
    const proxy = profile.parameters?.proxy || {};

    try {
      runXcli(["profile-stop", "--profile-id", id]);
    } catch {}

    const startOut = runXcli(["profile-start", "--profile-id", id, "--automation", "puppeteer"]);
    console.log(startOut.trim());

    const match = startOut.match(/port:\s*(\d+)/i);
    if (!match) throw new Error(`Could not parse port for ${name}`);
    port = match[1];

    await waitForDebugPort(port);

    const browser = await puppeteer.connect({
      browserURL: `http://127.0.0.1:${port}`
    });

    const page = await browser.newPage();

    if (proxy.username && proxy.password) {
      await page.authenticate({
        username: proxy.username,
        password: proxy.password
      });
    }

    const url = `${BASE_URL}?profileName=${encodeURIComponent(name)}&runId=batch-${Date.now()}`;
    await page.goto(url, { waitUntil: "networkidle2", timeout: 120000 });

    const sessionId = await page.evaluate(() => window.sessionId);
    console.log(`SESSION ${name}: ${sessionId}`);

    await page.evaluate(async () => {
      await window.runFullPqpCapture();
      await window.runAnalyze();
    });

    const finalSessionId = await page.evaluate(() => window.sessionId);
    console.log(`DONE ${name}: ${finalSessionId}`);

    await browser.disconnect();
  } catch (err) {
    console.error(`FAILED ${name}:`, err.message || err);
  } finally {
    try {
      runXcli(["profile-stop", "--profile-id", id]);
      console.log(`STOPPED ${name}`);
    } catch (err) {
      console.error(`STOP FAILED ${name}:`, err.message || err);
    }
  }
}

for (const profile of profiles) {
  await runProfile(profile);
  await new Promise(resolve => setTimeout(resolve, 5000));
}

console.log("\nBatch complete");
