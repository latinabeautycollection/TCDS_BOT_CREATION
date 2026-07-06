const base = process.env.PQP_BASE_URL || "http://127.0.0.1:8088";

async function main() {
  const res = await fetch(`${base}/api/pqp/qa/report/generate`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({})
  });

  const json = await res.json();

  if (!res.ok) {
    throw new Error(JSON.stringify(json));
  }

  console.log(JSON.stringify(json.summary, null, 2));
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
