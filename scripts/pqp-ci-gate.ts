const base = process.env.PQP_BASE_URL || "http://localhost:8088";
const minScore = Number(process.env.PQP_CI_MIN_SCORE || 60);

async function main() {
  const res = await fetch(`${base}/api/pqp/dashboard/summary`);
  if (!res.ok) throw new Error(`PQP dashboard summary failed: ${res.status}`);

  const summary: any = await res.json();

  console.log("PQP summary:", summary);

  if (!summary.sessions || Number(summary.sessions) < 1) {
    throw new Error("PQP CI gate failed: no sessions scored");
  }

  if (summary.avg_score !== null && Number(summary.avg_score) < minScore) {
    throw new Error(`PQP CI gate failed: avg score below threshold ${minScore}`);
  }

  console.log("PQP CI gate passed");
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
