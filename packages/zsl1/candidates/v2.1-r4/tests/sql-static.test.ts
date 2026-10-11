import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("migration contains required Green Tier 1 authority controls",async()=>{
  const s=await readFile("database/migrations/001_zsl1_green_tier1_v2.sql","utf8");
  const required=[
    "source_releases","source_artifacts","raw_records","release_record_memberships",
    "schema_contracts","schema_validation_runs","ingest_runs","ingest_attempts",
    "source_policies","ingest_audit_events","certification_policies","certification_runs",
    "transition_ingest_state","prevent_mutation","certified_release_records",
    "REVOKE ALL ON SCHEMA zsl_raw FROM PUBLIC"
  ];
  for(const token of required) assert.ok(s.includes(token),`missing ${token}`);
});
