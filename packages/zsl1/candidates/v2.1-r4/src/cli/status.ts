import { pool } from "../repositories/db.js";
const r=await pool.query(`
SELECT s.source_key,sr.release_key,ir.ingest_run_id,ir.state,ir.parsed_record_count,
       cr.status certification_status,cr.certified_at
FROM zsl.source_registry s
JOIN zsl.source_releases sr ON sr.source_id=s.source_id
LEFT JOIN LATERAL(SELECT * FROM zsl.ingest_runs x WHERE x.release_id=sr.release_id ORDER BY x.started_at DESC LIMIT 1)ir ON true
LEFT JOIN LATERAL(SELECT * FROM zsl.certification_runs c WHERE c.ingest_run_id=ir.ingest_run_id ORDER BY c.created_at DESC LIMIT 1)cr ON true
ORDER BY s.source_key,sr.release_key DESC`);
console.table(r.rows);await pool.end();
