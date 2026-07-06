import fs from "fs";
import { execFileSync, spawnSync } from "child_process";

const CLI_DIR = "/home/mloginops/mlx/deps/cli";
const XCLI = `${CLI_DIR}/xcli`;
const MAP = "/srv/pqp/reports/mlx/mlx-profile-map.tsv";
const TMP = "/home/mloginops/tmp/mlx-recreate";

const profileName = process.env.PROFILE_NAME;
if (!profileName) throw new Error("Set PROFILE_NAME=ML-US-011");

fs.mkdirSync(TMP, { recursive: true });

function sh(args, opts = {}) {
  return execFileSync(XCLI, args, {
    cwd: CLI_DIR,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    ...opts
  });
}

function dumpProfile(profileId, outFile) {
  const editor = `${TMP}/dump-${profileId}.sh`;
  fs.writeFileSync(editor, `#!/usr/bin/env bash
set -euo pipefail
cp "$1" "${outFile}"
exit 0
`);
  fs.chmodSync(editor, 0o755);

  sh(["profile-update", "--profile-id", profileId], {
    env: { ...process.env, XEDITOR: editor, EDITOR: editor, VISUAL: editor }
  });
}

function updateProfile(profileId, patchFile) {
  const editor = `${TMP}/patch-${profileId}.sh`;
  fs.writeFileSync(editor, `#!/usr/bin/env bash
set -euo pipefail
cp "${patchFile}" "$1"
exit 0
`);
  fs.chmodSync(editor, 0o755);

  sh(["profile-update", "--profile-id", profileId], {
    env: { ...process.env, XEDITOR: editor, EDITOR: editor, VISUAL: editor }
  });
}

function profileMap() {
  return fs.readFileSync(MAP, "utf8")
    .trim()
    .split("\n")
    .map(line => {
      const [name, id] = line.split("\t");
      return { name, id };
    });
}

function getIdFromMap(name) {
  const row = profileMap().find(p => p.name === name);
  if (!row) throw new Error(`Profile ${name} not found in ${MAP}`);
  return row.id;
}

function findActiveProfileId(name) {
  let raw = "";
  for (const offset of [0, 50, 100, 150, 200, 250]) {
    raw += sh(["profile-list", "-l", "50", "-o", String(offset)]) + "\n";
  }

  const line = raw
    .split("\n")
    .find(l => new RegExp(`^[0-9a-f-]{36}\\s+${name}\\b`).test(l));

  if (!line) throw new Error(`Could not find recreated ${name} in profile-list`);
  return line.trim().split(/\s+/)[0];
}

function updateMap(name, newId) {
  const lines = fs.readFileSync(MAP, "utf8").trim().split("\n");
  const next = lines.map(line => {
    const [n] = line.split("\t");
    return n === name ? `${name}\t${newId}` : line;
  });
  fs.writeFileSync(MAP, next.join("\n") + "\n");
}

const oldId = getIdFromMap(profileName);
const oldBackup = `${TMP}/${profileName}-old-${oldId}.json`;

console.log(`Backing up ${profileName} ${oldId}`);
dumpProfile(oldId, oldBackup);

const oldProfile = JSON.parse(fs.readFileSync(oldBackup, "utf8"));
const proxy = oldProfile.parameters?.proxy || {};
const flags = oldProfile.parameters?.flags || {};
const fingerprint = oldProfile.parameters?.fingerprint || {};
const storage = oldProfile.parameters?.storage || {};

console.log(`Removing old profile to trash: ${oldId}`);
sh(["profile-remove", "--values", oldId]);

const createArgs = [
  "profile-create",
  "--name", profileName,
  "--os-type", "linux",
  "--browser-type", "mimic",
  "--cloud",
  "--proxy-type", proxy.type || "http",
  "--proxy-host", proxy.host,
  "--proxy-port", String(proxy.port || 8080),
  "--proxy-username", proxy.username || "",
  "--proxy-password", proxy.password || "",
  "--timezone-masking", flags.timezone_masking === "custom" ? "mask" : (flags.timezone_masking || "natural"),
  "--localization-masking", flags.localization_masking === "custom" ? "mask" : (flags.localization_masking || "natural"),
  "--geolocation-popup", flags.geolocation_popup || "prompt",
  "--graphics-masking", flags.graphics_masking === "custom" ? "mask" : (flags.graphics_masking || "natural"),
  "--graphics-noise", flags.graphics_noise || "natural",
  "--audio-masking", flags.audio_masking || "natural",
  "--fonts-masking", flags.fonts_masking || "natural",
  "--media-devices-masking", flags.media_devices_masking || "natural",
  "--navigator-masking", flags.navigator_masking || "natural",
  "--ports-masking", flags.ports_masking || "natural",
  "--screen-masking", flags.screen_masking || "natural",
  "--webrtc-masking", flags.webrtc_masking || "natural"
];

console.log(`Creating replacement ${profileName}`);
console.log(sh(createArgs).trim());

const newId = findActiveProfileId(profileName);
const newBackup = `${TMP}/${profileName}-new-${newId}.json`;
dumpProfile(newId, newBackup);

const newProfile = JSON.parse(fs.readFileSync(newBackup, "utf8"));
newProfile.parameters ||= {};
newProfile.parameters.proxy = proxy;
newProfile.parameters.flags = {
  ...(newProfile.parameters.flags || {}),
  ...flags
};
newProfile.parameters.fingerprint = fingerprint;
newProfile.parameters.storage = storage;

const patchFile = `${TMP}/${profileName}-patch-${newId}.json`;
fs.writeFileSync(patchFile, JSON.stringify(newProfile, null, 2));

console.log(`Applying old proxy/fingerprint config to new profile ${newId}`);
updateProfile(newId, patchFile);

console.log(`Updating map ${profileName}: ${oldId} -> ${newId}`);
updateMap(profileName, newId);

console.log(`Testing server start`);
const start = spawnSync(XCLI, ["profile-start", "--profile-id", newId, "--automation", "puppeteer"], {
  cwd: CLI_DIR,
  encoding: "utf8"
});

console.log(start.stdout || "");
console.error(start.stderr || "");

if (start.status !== 0) {
  throw new Error(`Replacement profile still failed to start: ${start.stdout || start.stderr}`);
}

sh(["profile-stop", "--profile-id", newId]);

console.log(JSON.stringify({
  ok: true,
  profileName,
  oldId,
  newId,
  backup: oldBackup,
  map: MAP
}, null, 2));
