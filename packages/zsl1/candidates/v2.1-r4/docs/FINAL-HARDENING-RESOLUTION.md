# Final Hardening Resolution

This V2 package implements the remediation directives from the attached V1 peer review.

## P0
- TypeScript/Node 22 production runtime.
- Explicit HUD year+quarter release identity.
- Content-addressed raw records separated from release membership.
- Transactional load/reconciliation preventing partial retry poisoning.
- Central credential redaction.
- Original artifact custody with SHA/size/source/storage URI.
- Fail-closed artifact/record schema checks.
- Explicit ingest state machine separate from certification state.
- Supabase/PostgreSQL RBAC and PUBLIC revocation.
- ACS profiles support State, County, Place and ZCTA.

## P1
- Governed BEA table/line/geography parameters.
- Governed FAF release URL; no landing-page auto-activation.
- Bounded retries and permanent-error fail close.
- Source+release advisory lock.
- Release/retrieval/ingest/artifact identities separated.
- Strong SHA/count/JSON/timestamp constraints.
- Immutable artifact/raw-record/membership evidence.
- App/git/package/policy/adapter provenance.
- Exact direct dependency versions and SBOM.
- Automated static tests.
- Certification engine and certified-only downstream view.

## Runtime caveats
The exact package still requires live Supabase execution and real federal-source ingestion. Therefore this artifact is an implementation-final candidate, not a runtime-certified release.
