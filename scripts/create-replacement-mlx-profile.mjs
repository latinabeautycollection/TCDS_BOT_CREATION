import fs from "fs";
import { execFileSync, spawnSync } from "child_process";

const CLI_DIR = "/home/mloginops/mlx/deps/cli";
const XCLI = `${CLI_DIR}/xcli`;
const MAP = "/srv/pqp/reports/mlx/mlx-profile-map.tsv";

const profileName = process.env.PROFILE_NAME;
const backupFile = process.env.BACKUP_FILE;

if (!profileName) throw new Error("Set PROFILE_NAME");
if (!backupFile) throw new Error("Set BACKUP_FILE");

const oldProfile = JSON.parse(fs.readFileSync(backupFile, "utf8"));
const proxy = oldProfile.parameters?.proxy || {};
const flags = oldProfile.parameters?.flags || {};
const fingerprint = oldProfile.parameters?.fingerprint || {};
const storage = oldProfile.parameters?.storage || {};

function run(args) {
  return execFileSync(XCLI, args, {
    cwd: CLI_DIR,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  });
}

function listAll() {
  let raw = "";
  for (const offset of [0, 50, 100, 150, 200, 250]) {
    try {
      raw += run(["profile-list", "-l", "50", "-o", String(offset)]) + "\n";
    } catch {}
  }
  return raw;
}

function findProfileId(name) {
  const raw = listAll();
  const line = raw.split("\n").find(l => new RegExp(`^[0-9a-f-]{36}\\s+${name}\\b`).test(l));
  return line ? line.trim().split(/\s+/)[0] : null;
}

function updateMap(name, newId) {
  const lines = fs.readFileSync(MAP, "utf8").trim().split("\n");
  let replaced = false;

  const next = lines.map(line => {
    const [n] = line.split("\t");
    if (n === name) {
      replaced = true;
      return `${name}\t${newId}`;
    }
    return line;
  });

  if (!replaced) next.push(`${name}\t${newId}`);
  fs.writeFileSync(MAP, next.join("\n") + "\n");
}

function updateProfile(profileId, fullProfile) {
  const tmpDir = "/home/mloginops/tmp/mlx-recreate";
  fs.mkdirSync(tmpDir, { recursive: true });

  const patchFile = `${tmpDir}/${profileName}-replacement-${profileId}.json`;
  const editor = `${tmpDir}/patch-${profileName}-${profileId}.sh`;

  fs.writeFileSync(patchFile, JSON.stringify(fullProfile, null, 2));
  fs.writeFileSync(editor, `#!/usr/bin/env bash
set -euo pipefail
cp "${patchFile}" "$1"
exit 0
`);
  fs.chmodSync(editor, 0o755);

  execFileSync(XCLI, ["profile-update", "--profile-id", profileId], {
    cwd: CLI_DIR,
    encoding: "utf8",
    env: { ...process.env, XEDITOR: editor, EDITOR: editor, VISUAL: editor },
    stdio: ["ignore", "pipe", "pipe"]
  });
}

console.log(`Creating ${profileName}`);

let created = "";
try {
  created = run([
    "profile-create",
    "--name", profileName,
    "--os-type", "linux",
    "--browser-type", "mimic",
    "--cloud",
    "--proxy-type", proxy.type || "http",
    "--proxy-string", `${proxy.host}:${proxy.port}:${proxy.username}:${proxy.password}`
  ]);
} catch (err) {
  console.error(err.stdout || "");
  console.error(err.stderr || "");
  throw err;
}

console.log(created.trim());

const newId = findProfileId(profileName);
if (!newId) throw new Error(`Could not find new ID for ${profileName}`);

console.log(`New ID: ${newId}`);

let newProfile = structuredClone(oldProfile);
newProfile.name = profileName;
newProfile.parameters ||= {};
newProfile.parameters.proxy = proxy;
newProfile.parameters.flags = flags;
newProfile.parameters.fingerprint = fingerprint;
newProfile.parameters.storage = storage;

console.log("Applying saved proxy/config");
updateProfile(newId, newProfile);

console.log("Updating map");
updateMap(profileName, newId);

console.log("Testing start");
const start = spawnSync(XCLI, ["profile-start", "--profile-id", newId, "--automation", "puppeteer"], {
  cwd: CLI_DIR,
  encoding: "utf8"
});

console.log(start.stdout || "");
console.error(start.stderr || "");

if (start.status !== 0) {
  throw new Error("New profile created but failed to start");
}

run(["profile-stop", "--profile-id", newId]);

console.log(JSON.stringify({ ok: true, profileName, newId }, null, 2));
