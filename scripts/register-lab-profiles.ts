import fs from "node:fs/promises";

const base = process.env.PQP_BASE_URL || "http://localhost:8088";
const file = process.env.PQP_PROFILE_FILE || "data/lab/profiles.example.json";

async function main() {
  const raw = await fs.readFile(file, "utf8");
  const profiles = JSON.parse(raw);

  for (const p of profiles) {
    const res = await fetch(`${base}/api/pqp/lab/profile`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify(p)
    });

    const json = await res.json().catch(() => ({}));

    if (!res.ok) {
      throw new Error(`Failed to register ${p.profileName}: ${JSON.stringify(json)}`);
    }

    console.log(`Registered ${p.profileName}`);
  }
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
