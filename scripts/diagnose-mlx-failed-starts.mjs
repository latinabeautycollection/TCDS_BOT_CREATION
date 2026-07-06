import fs from "fs";
import { spawnSync } from "child_process";

const CLI_DIR = "/home/mloginops/mlx/deps/cli";
const XCLI = `${CLI_DIR}/xcli`;
const FAILED_FILE = "/home/mloginops/tmp/mlx-batch/failed-profiles.json";
const OUT_FILE = "/home/mloginops/tmp/mlx-batch/failed-start-diagnostics.json";

const failed = JSON.parse(fs.readFileSync(FAILED_FILE, "utf8"));
const results = [];

function run(args) {
  return spawnSync(XCLI, args, {
    cwd: CLI_DIR,
    encoding: "utf8"
  });
}

for (const p of failed) {
  console.log(`\nDIAG ${p.name} ${p.id}`);

  const stopBefore = run(["profile-stop", "--profile-id", p.id]);

  const start = run(["profile-start", "--profile-id", p.id, "--automation", "puppeteer"]);

  let port = null;
  const combined = `${start.stdout || ""}\n${start.stderr || ""}`;
  const match = combined.match(/port:\s*(\d+)/i);
  if (match) port = match[1];

  const stopAfter = run(["profile-stop", "--profile-id", p.id]);

  const row = {
    name: p.name,
    id: p.id,
    startStatus: start.status,
    startSignal: start.signal,
    startStdout: start.stdout,
    startStderr: start.stderr,
    parsedPort: port,
    stopBeforeStatus: stopBefore.status,
    stopBeforeStdout: stopBefore.stdout,
    stopBeforeStderr: stopBefore.stderr,
    stopAfterStatus: stopAfter.status,
    stopAfterStdout: stopAfter.stdout,
    stopAfterStderr: stopAfter.stderr
  };

  results.push(row);

  console.log(JSON.stringify({
    name: row.name,
    startStatus: row.startStatus,
    parsedPort: row.parsedPort,
    startStdout: row.startStdout,
    startStderr: row.startStderr
  }, null, 2));
}

fs.writeFileSync(OUT_FILE, JSON.stringify(results, null, 2));
console.log(`\nWrote ${OUT_FILE}`);
