-- TCDS 042d: executable ZSL1 source precedence + DB-backed national publication readiness
BEGIN;
CREATE OR REPLACE VIEW zsl_tax_acq.v_authority_conflicts AS
WITH base AS (
 SELECT c.*,r.status release_status,cert.status certification_status,
        min(c.authority_rank) OVER(PARTITION BY c.state_code,c.record_type,c.natural_key,coalesce(c.effective_from,'-infinity'::timestamptz),coalesce(c.effective_to,'infinity'::timestamptz)) min_rank
 FROM zsl_tax_acq.canonical_records c
 JOIN zsl.source_releases r ON r.release_id=c.release_id AND r.status='RECONCILED'
 JOIN zsl.certification_runs cert ON cert.ingest_run_id=c.ingest_run_id AND cert.status='CERTIFIED'
), top_rank AS (
 SELECT * FROM base WHERE authority_rank=min_rank
), grouped AS (
 SELECT state_code,record_type family,natural_key,effective_from,effective_to,authority_rank,count(DISTINCT record_sha256) conflicting_hashes,array_agg(canonical_record_id ORDER BY record_sha256,canonical_record_id) record_ids
 FROM top_rank GROUP BY state_code,record_type,natural_key,effective_from,effective_to,authority_rank
)
SELECT * FROM grouped WHERE conflicting_hashes>1;

CREATE OR REPLACE VIEW zsl_tax_acq.v_authoritative_records AS
WITH base AS (
 SELECT c.*,min(c.authority_rank) OVER(PARTITION BY c.state_code,c.record_type,c.natural_key,coalesce(c.effective_from,'-infinity'::timestamptz),coalesce(c.effective_to,'infinity'::timestamptz)) min_rank
 FROM zsl_tax_acq.canonical_records c
 JOIN zsl.source_releases r ON r.release_id=c.release_id AND r.status='RECONCILED'
 JOIN zsl.certification_runs cert ON cert.ingest_run_id=c.ingest_run_id AND cert.status='CERTIFIED'
), eligible AS (
 SELECT b.*,row_number() OVER(PARTITION BY b.state_code,b.record_type,b.natural_key,coalesce(b.effective_from,'-infinity'::timestamptz),coalesce(b.effective_to,'infinity'::timestamptz) ORDER BY b.authority_rank,b.published_at DESC NULLS LAST,b.created_at DESC,b.record_sha256,b.canonical_record_id) rn
 FROM base b
 WHERE b.authority_rank=b.min_rank
   AND NOT EXISTS(SELECT 1 FROM zsl_tax_acq.v_authority_conflicts x WHERE x.state_code=b.state_code AND x.family=b.record_type AND x.natural_key=b.natural_key AND x.effective_from IS NOT DISTINCT FROM b.effective_from AND x.effective_to IS NOT DISTINCT FROM b.effective_to)
)
SELECT * FROM eligible WHERE rn=1;

CREATE OR REPLACE VIEW zsl_tax_acq.v_certified_family_cells AS
WITH expected AS (SELECT j.state_code,f.family FROM zsl_tax_acq.jurisdiction_registry j CROSS JOIN zsl_tax_acq.family_registry f WHERE j.enabled AND f.enabled),
auth AS (SELECT DISTINCT state_code,record_type family FROM zsl_tax_acq.v_authoritative_records),
neg AS (
 SELECT DISTINCT a.state_code,a.family,a.assertion_id
 FROM zsl_tax_acq.applicability_assertions a
 JOIN zsl.source_releases sr ON sr.release_id=a.release_id AND sr.status='RECONCILED'
 WHERE a.review_status='APPROVED'
   AND EXISTS(SELECT 1 FROM zsl.ingest_runs i JOIN zsl.certification_runs c ON c.ingest_run_id=i.ingest_run_id AND c.status='CERTIFIED' WHERE i.release_id=a.release_id)
), cov AS (SELECT * FROM zsl_tax_acq.family_coverage_attestations WHERE status='PASS')
SELECT e.state_code,e.family,
 CASE
   WHEN cov.applicability_assertion_id IS NOT NULL AND neg.assertion_id=cov.applicability_assertion_id THEN 'CERTIFIED_NOT_APPLICABLE'
   WHEN auth.state_code IS NOT NULL AND cov.state_code IS NOT NULL THEN 'CERTIFIED'
   ELSE 'MISSING'
 END status,
 CASE WHEN cov.applicability_assertion_id IS NOT NULL THEN cov.applicability_assertion_id ELSE neg.assertion_id END assertion_id,
 cov.evidence_sha256 coverage_evidence_sha256
FROM expected e
LEFT JOIN auth USING(state_code,family)
LEFT JOIN neg USING(state_code,family)
LEFT JOIN cov USING(state_code,family);

CREATE OR REPLACE VIEW zsl_tax_acq.v_national_readiness AS
SELECT
 (SELECT count(*) FROM zsl_tax_acq.v_certified_family_cells) family_expected,
 (SELECT count(*) FROM zsl_tax_acq.v_certified_family_cells WHERE status IN('CERTIFIED','CERTIFIED_NOT_APPLICABLE')) family_certified,
 51::bigint local_expected,(SELECT count(*) FROM zsl_tax_acq.local_authority_coverage WHERE status='PASS') local_certified,
 51::bigint resolution_expected,(SELECT count(*) FROM zsl_tax_acq.address_resolution_quality WHERE status='PASS') resolution_certified,
 ((SELECT count(*) FROM zsl_tax_acq.conflicts WHERE severity='FATAL' AND resolved=false)+(SELECT count(*) FROM zsl_tax_acq.v_authority_conflicts)) fatal_conflicts,
 ((SELECT count(*) FROM zsl_tax_acq.v_certified_family_cells)=1071
   AND (SELECT count(*) FROM zsl_tax_acq.v_certified_family_cells WHERE status IN('CERTIFIED','CERTIFIED_NOT_APPLICABLE'))=1071
   AND (SELECT count(*) FROM zsl_tax_acq.local_authority_coverage WHERE status='PASS')=51
   AND (SELECT count(*) FROM zsl_tax_acq.address_resolution_quality WHERE status='PASS')=51
   AND ((SELECT count(*) FROM zsl_tax_acq.conflicts WHERE severity='FATAL' AND resolved=false)+(SELECT count(*) FROM zsl_tax_acq.v_authority_conflicts))=0) ready;
COMMIT;
