import{pool}from'../repositories/db.js';import{sha256Canonical}from'../core/hash.js';
const run=process.argv[2],code=process.argv[3],status=process.argv[4];if(!run||!code||!['PASS','FAIL'].includes(status??''))throw new Error('usage: record-evidence <build_run_id> <evidence_code> <PASS|FAIL>');
const evidence=JSON.parse(process.env.ZSL3_QA_EVIDENCE_JSON??'{}');const actor=process.env.ZSL3_QA_ACTOR??'zsl3-qa';
await pool.query(`INSERT INTO zsl.zsl3_qa_evidence(build_run_id,evidence_code,status,evidence,evidence_sha256,actor) VALUES($1,$2,$3,$4::jsonb,$5,$6)`,[run,code,status,JSON.stringify(evidence),sha256Canonical(evidence),actor]);await pool.end();
