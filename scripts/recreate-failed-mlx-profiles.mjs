import fs from "fs";
import { execFileSync, spawnSync } from "child_process";

const CLI_DIR = "/home/mloginops/mlx/deps/cli";
const XCLI = `${CLI_DIR}/xcli`;
const MAP = "/srv/pqp/reports/mlx/mlx-profile-map.tsv";
const FAILED_FILE = "/home/mloginops/tmp/mlx-batch/failed-profiles.json";
const TMP = "/home/mloginops/tmp/mlx-recreate";

fs.mkdirSync(TMP, { recursive: true });

function run(args, opts = {}) {
  return execFileSync(XCLI, args, {
    cwd: CLI_DIR,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    ...opts
  });
}

function dumpProfile(profileName, profileId, outFile) {
  const editor = `${TMP}/dump-${profileName}-${profileId}.sh`;
  fs.writeFileSync(editor, `#!/usr/bin/env bash
set -euo pipefail
cp "$1" "${outFile}"
exit 0
`);
  fs.chmodSync(editor, 0o755);

  run(["profile-update", "--profile-id", profileId], {
    env: { ...process.env, XEDITOR: editor, EDITOR: editor, VISUAL: editor }
  });
}

function listAll() {
  let raw = "";
  for (const offset of [0, 50, 100, 150, 200, 250]) {
    try { raw += run(["profile-list", "-l", "50", "-o", String(offset)]) + "\n"; } catch {}
  }
  return raw;
}

function findProfileId(name) {
  const raw = listAll();
  const line = raw.split("\n").find(l => new RegExp(`^[0-9a-f-]{36}\\s+${name}\\b`).test(l));
  return line ? line.trim().split(/\s+/)[0] : null;
}

function updateMap(name, oldId, newId) {
  const lines = fs.readFileSync(MAP, "utf8").trim().split("\n");
  let replaced = false;

  const next = lines.map(line => {
    const [n, id] = line.split("\t");
    if (n === name || id === oldId) {
      replaced = true;
      return `${name}\t${newId}`;
    }
    return line;
  });

  if (!replaced) next.push(`${name}\t${newId}`);
  fs.writeFileSync(MAP, next.join("\n") + "\n");
}

function updateProfile(profileName, profileId, fullProfile) {
  const patchFile = `${TMP}/${profileName}-patch-${profileId}.json`;
  const editor = `${TMP}/patch-${profileName}-${profileId}.sh`;

  fs.writeFileSync(patchFile, JSON.stringify(fullProfile, null, 2));
  fs.writeFileSync(editor, `#!/usr/bin/env bash
set -euo pipefail
cp "${patchFile}" "$1"
exit 0
`);
  fs.chmodSync(editor, 0o755);

  run(["profile-update", "--profile-id", profileId], {
    env: { ...process.env, XEDITOR: editor, EDITOR: editor, VISUAL: editor }
  });
}

function createReplacement(profileName, oldProfile) {
  const proxy = oldProfile.parameters?.proxy || {};
  const out = run([
    "profile-create",
    "--name", profileName,
    "--os-type", "linux",
    "--browser-type", "mimic",
    "--cloud",
    "--proxy-type", proxy.type || "http",
    "--proxy-string", `${proxy.host}:${proxy.port}:${proxy.username}:${proxy.password}`
  ]);

  console.log(out.trim());

  const newId = findProfileId(profileName);
  if (!newId) throw new Error(`Could not find new ID for ${profileName}`);

  const nextProfile = structuredClone(oldProfile);
  nextProfile.name = profileName;

  updateProfile(profileName, newId, nextProfile);

  return newId;
}

function testStart(profileName, newId) {
  const start = spawnSync(XCLI, ["profile-start", "--profile-id", newId, "--automation", "puppeteer"], {
    cwd: CLI_DIR,
    encoding: "utf8"
  });

  const ok = start.status === 0;
  console.log(start.stdout || "");
  console.error(start.stderr || "");

  if (ok) {
    try { run(["profile-stop", "--profile-id", newId]); } catch {}
  }

  return ok;
}

const failed = JSON.parse(fs.readFileSync(FAILED_FILE, "utf8"));
const remaining = [];
const recreated = [];

for (const p of failed) {
  console.log(`\nRECREATE ${p.name} ${p.id}`);

  try {
    const backupFile = `${TMP}/${p.name}-old-${p.id}.json`;

    if (!fs.existsSync(backupFile)) {
      console.log("Backing up old profile");
      dumpProfile(p.name, p.id, backupFile);
    }

    const oldProfile = JSON.parse(fs.readFileSync(backupFile, "utf8"));

    console.log("Force deleting old profile");
    try { run(["profile-remove", "--force", "--values", p.id]); } catch (err) {
      console.log("Remove note:", (err.stdout || err.stderr || err.message || "").trim());
    }

    console.log("Creating replacement");
    const newId = createReplacement(p.name, oldProfile);

    console.log(`Updating map ${p.id} -> ${newId}`);
    updateMap(p.name, p.id, newId);

    console.log("Testing server start");
    const ok = testStart(p.name, newId);

    if (!ok) {
      remaining.push({ name: p.name, id: newId, reason: "replacement_created_but_start_failed", oldId: p.id });
      continue;
    }

    recreated.push({ name: p.name, oldId: p.id, newId });
    console.log(`OK ${p.name} ${newId}`);
  } catch (err) {
    console.error(`FAILED ${p.name}:`, err.message || err);
    remaining.push(p);
  }
}

fs.writeFileSync(FAILED_FILE, JSON.stringify(remaining, null, 2));
fs.writeFileSync(`${TMP}/bulk-recreated-${Date.now()}.json`, JSON.stringify(recreated, null, 2));

console.log(JSON.stringify({
  attempted: failed.length,
  recreated: recreated.length,
  remaining: remaining.length,
  remainingNames: remaining.map(p => p.name)
}, null, 2));
