# ZSL1 V2.1 Final Freeze Remediation Map

| Prior risk | V2.1 remediation |
|---|---|
| Gazetteer parser assumed pipe delimiter | Auto-detects tab/pipe and validates header |
| ZCTA incorrectly required NAME | Correct ZCTA source contract with GEOID/GEOIDFQ |
| HUD expected uppercase ZIP/COUNTY/CBSA | Uses documented lowercase `zip` + `geoid` result contract |
| HUD release could drift | Response year/quarter/crosswalk must equal requested release |
| ACS variable semantics unbound | Vintage-specific variable metadata SHA sealed into validation evidence |
| BEA table assumed without metadata evidence | Regional metadata is queried and bound |
| FAF CSV split by comma / full-buffer unzip | Streaming CSV parser + streaming unzip |
| ZIP compression ratio not enforced | Compressed vs expanded ratio guard |
| HTTP magic read whole file | Bounded 256-byte magic inspection |
| Artifact path traversal through release | All artifact path segments sanitized |
| Duplicate release artifact blocked retry | Artifact uniqueness moved to exact ingest run |
| Certification counted prior-run membership | Membership explicitly bound to ingest_run_id |
| Raw record natural key could be inherited from another source | Downstream authority uses run membership natural_key |
| Parser replay only promised | Replay executes and ordered SHA must reproduce |
| Schema validation table unused | Validation evidence inserted and required by cert |
| Audit not tied to run | ingest_run_id FK + required audit event set |
| Policy/contract same-version mutation | Content immutable; version reuse with different SHA rejected |
| Certified release could be silently edited | Certified release mutation trigger |
| DB TLS allowed rejectUnauthorized=false by default | TLS verification defaults true |
| Certification relied on optional package env fallback | Exact run-bound package SHA must equal deployment SHA |
| PostgreSQL could accept weak CERTIFIED row | certification_insert_guard enforces reconciliation/schema/replay |
