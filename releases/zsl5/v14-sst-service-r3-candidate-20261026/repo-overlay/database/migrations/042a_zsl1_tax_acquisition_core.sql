-- TCDS 042a: ZSL1 national tax acquisition core v1.4 integration
-- Additive only. No Retail/ARB/PQP/CAX mutations.
BEGIN;

DO $preflight$
BEGIN
 IF to_regclass('zsl.source_registry') IS NULL OR to_regclass('zsl.ingest_runs') IS NULL OR to_regclass('zsl_raw.raw_records') IS NULL THEN
  RAISE EXCEPTION 'ZSL1_BASELINE_REQUIRED';
 END IF;
 IF to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN RAISE EXCEPTION 'PGCRYPTO_DIGEST_REQUIRED'; END IF;
END $preflight$;

CREATE SCHEMA IF NOT EXISTS zsl_tax_acq;

CREATE TABLE IF NOT EXISTS zsl_tax_acq.family_registry(
 family text PRIMARY KEY, ordinal integer NOT NULL UNIQUE CHECK(ordinal BETWEEN 1 AND 21), enabled boolean NOT NULL DEFAULT true
);
INSERT INTO zsl_tax_acq.family_registry(family,ordinal) VALUES
('TAX_REGIME',1),
('TAX_JURISDICTION',2),
('TAX_JURISDICTION_ASSIGNMENT',3),
('STATE_RATE',4),
('LOCAL_RATE',5),
('RATE_COMPONENT_RULE',6),
('RATE_CAP_THRESHOLD_RULE',7),
('PRODUCT_TAXABILITY',8),
('TAXABLE_BASE_RULE',9),
('BUNDLED_TRANSACTION_RULE',10),
('ALLOCATION_RULE',11),
('TAX_HOLIDAY',12),
('SOURCING_RULE',13),
('SELLER_COLLECTION_RULE',14),
('MARKETPLACE_RULE',15),
('SELLER_TAX_ELECTION',16),
('EXEMPTION_RULE',17),
('EXEMPTION_CERTIFICATE_REQUIREMENT',18),
('TAX_CREDIT_RULE',19),
('ROUNDING_RULE',20),
('MANDATORY_TRANSACTION_FEE',21)
ON CONFLICT(family) DO UPDATE SET ordinal=EXCLUDED.ordinal,enabled=true;

CREATE TABLE IF NOT EXISTS zsl_tax_acq.jurisdiction_registry(
 state_code char(2) PRIMARY KEY CHECK(state_code~'^[A-Z]{2}$'), enabled boolean NOT NULL DEFAULT true
);
INSERT INTO zsl_tax_acq.jurisdiction_registry(state_code) VALUES
('AL'),
('AK'),
('AZ'),
('AR'),
('CA'),
('CO'),
('CT'),
('DE'),
('FL'),
('GA'),
('HI'),
('ID'),
('IL'),
('IN'),
('IA'),
('KS'),
('KY'),
('LA'),
('ME'),
('MD'),
('MA'),
('MI'),
('MN'),
('MS'),
('MO'),
('MT'),
('NE'),
('NV'),
('NH'),
('NJ'),
('NM'),
('NY'),
('NC'),
('ND'),
('OH'),
('OK'),
('OR'),
('PA'),
('RI'),
('SC'),
('SD'),
('TN'),
('TX'),
('UT'),
('VT'),
('VA'),
('WA'),
('WV'),
('WI'),
('WY'),
('DC')
ON CONFLICT(state_code) DO UPDATE SET enabled=true;

CREATE TABLE IF NOT EXISTS zsl_tax_acq.canonical_records(
 canonical_record_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 ingest_run_id uuid NOT NULL REFERENCES zsl.ingest_runs(ingest_run_id) ON DELETE RESTRICT,
 release_id uuid NOT NULL REFERENCES zsl.source_releases(release_id) ON DELETE RESTRICT,
 artifact_id uuid NOT NULL REFERENCES zsl.source_artifacts(artifact_id) ON DELETE RESTRICT,
 raw_record_id uuid REFERENCES zsl_raw.raw_records(record_id) ON DELETE RESTRICT,
 record_type text NOT NULL,
 state_code char(2) NOT NULL REFERENCES zsl_tax_acq.jurisdiction_registry(state_code),
 natural_key text NOT NULL CHECK(length(btrim(natural_key))>0),
 authority_rank integer NOT NULL CHECK(authority_rank IN(1,2,3,4,5,99)),
 published_at timestamptz, effective_from timestamptz, effective_to timestamptz, legal_citation text,
 record_document jsonb NOT NULL CHECK(jsonb_typeof(record_document)='object'),
 record_sha256 text NOT NULL CHECK(record_sha256~'^[0-9a-f]{64}$'),
 parser_version text NOT NULL CHECK(btrim(parser_version)<>'' AND parser_version<>'PENDING_PARSE'),
 normalization_version text NOT NULL CHECK(btrim(normalization_version)<>''),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(ingest_run_id,record_sha256),
 CHECK(record_type IN('TAX_REGIME','TAX_JURISDICTION','TAX_JURISDICTION_ASSIGNMENT','STATE_RATE','LOCAL_RATE','RATE_COMPONENT_RULE','RATE_CAP_THRESHOLD_RULE','PRODUCT_TAXABILITY','TAXABLE_BASE_RULE','BUNDLED_TRANSACTION_RULE','ALLOCATION_RULE','TAX_HOLIDAY','SOURCING_RULE','SELLER_COLLECTION_RULE','MARKETPLACE_RULE','SELLER_TAX_ELECTION','EXEMPTION_RULE','EXEMPTION_CERTIFICATE_REQUIREMENT','TAX_CREDIT_RULE','ROUNDING_RULE','MANDATORY_TRANSACTION_FEE')),
 CHECK(effective_to IS NULL OR effective_from IS NULL OR effective_to>=effective_from)
);
ALTER TABLE zsl_tax_acq.canonical_records ADD COLUMN IF NOT EXISTS raw_record_id uuid REFERENCES zsl_raw.raw_records(record_id) ON DELETE RESTRICT;
ALTER TABLE zsl_tax_acq.canonical_records DROP CONSTRAINT IF EXISTS canonical_records_record_type_check;
ALTER TABLE zsl_tax_acq.canonical_records ADD CONSTRAINT canonical_records_record_type_check CHECK(record_type IN('TAX_REGIME','TAX_JURISDICTION','TAX_JURISDICTION_ASSIGNMENT','STATE_RATE','LOCAL_RATE','RATE_COMPONENT_RULE','RATE_CAP_THRESHOLD_RULE','PRODUCT_TAXABILITY','TAXABLE_BASE_RULE','BUNDLED_TRANSACTION_RULE','ALLOCATION_RULE','TAX_HOLIDAY','SOURCING_RULE','SELLER_COLLECTION_RULE','MARKETPLACE_RULE','SELLER_TAX_ELECTION','EXEMPTION_RULE','EXEMPTION_CERTIFICATE_REQUIREMENT','TAX_CREDIT_RULE','ROUNDING_RULE','MANDATORY_TRANSACTION_FEE'));
CREATE INDEX IF NOT EXISTS ix_zsl_tax_acq_lookup ON zsl_tax_acq.canonical_records(record_type,state_code,natural_key,effective_from,effective_to);
CREATE INDEX IF NOT EXISTS ix_zsl_tax_acq_raw ON zsl_tax_acq.canonical_records(raw_record_id);

CREATE TABLE IF NOT EXISTS zsl_tax_acq.conflicts(
 conflict_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), ingest_run_id uuid NOT NULL REFERENCES zsl.ingest_runs(ingest_run_id),
 severity text NOT NULL CHECK(severity IN('INFO','WARN','FATAL')), conflict_key text NOT NULL, evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'),
 evidence_sha256 text NOT NULL CHECK(evidence_sha256~'^[0-9a-f]{64}$'), resolved boolean NOT NULL DEFAULT false, resolution jsonb, created_at timestamptz NOT NULL DEFAULT now(), resolved_at timestamptz
);
CREATE INDEX IF NOT EXISTS ix_zsl_tax_acq_conflict_open ON zsl_tax_acq.conflicts(ingest_run_id,severity) WHERE resolved=false;

CREATE TABLE IF NOT EXISTS zsl_tax_acq.release_lineage(
 release_id uuid PRIMARY KEY REFERENCES zsl.source_releases(release_id) ON DELETE RESTRICT, supersedes_release_id uuid REFERENCES zsl.source_releases(release_id),
 correction_of_release_id uuid REFERENCES zsl.source_releases(release_id), publication_date date, effective_from date, effective_to date,
 lineage_document jsonb NOT NULL CHECK(jsonb_typeof(lineage_document)='object'), lineage_sha256 text NOT NULL CHECK(lineage_sha256~'^[0-9a-f]{64}$'),
 CHECK(effective_to IS NULL OR effective_from IS NULL OR effective_to>=effective_from)
);

CREATE TABLE IF NOT EXISTS zsl_tax_acq.applicability_assertions(
 assertion_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), state_code char(2) NOT NULL REFERENCES zsl_tax_acq.jurisdiction_registry(state_code),
 family text NOT NULL REFERENCES zsl_tax_acq.family_registry(family),
 assertion text NOT NULL CHECK(assertion IN('APPLIES','DOES_NOT_APPLY','NOT_AUTHORIZED','NO_GENERAL_TAX','NO_HOLIDAY','NO_LOCAL_TAX','NO_SPECIAL_FEE','NO_SELLER_ELECTION')),
 source_id uuid NOT NULL REFERENCES zsl.source_registry(source_id), release_id uuid NOT NULL REFERENCES zsl.source_releases(release_id), artifact_id uuid NOT NULL REFERENCES zsl.source_artifacts(artifact_id),
 legal_citation text, effective_from timestamptz, effective_to timestamptz, review_status text NOT NULL CHECK(review_status IN('PENDING','APPROVED','REJECTED')), reviewed_by text,
 evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'), evidence_sha256 text NOT NULL CHECK(evidence_sha256~'^[0-9a-f]{64}$'), created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(state_code,family,assertion,release_id,evidence_sha256), CHECK(effective_to IS NULL OR effective_from IS NULL OR effective_to>=effective_from)
);

CREATE TABLE IF NOT EXISTS zsl_tax_acq.local_authority_coverage(
 state_code char(2) PRIMARY KEY REFERENCES zsl_tax_acq.jurisdiction_registry(state_code), status text NOT NULL CHECK(status IN('NOT_CERTIFIED','PASS','FAIL')), coverage_mode text NOT NULL,
 jurisdictions_expected integer CHECK(jurisdictions_expected IS NULL OR jurisdictions_expected>=0), jurisdictions_certified integer NOT NULL DEFAULT 0 CHECK(jurisdictions_certified>=0),
 home_rule_expected integer CHECK(home_rule_expected IS NULL OR home_rule_expected>=0), home_rule_certified integer NOT NULL DEFAULT 0 CHECK(home_rule_certified>=0),
 certified_no_local_tax_assertion boolean NOT NULL DEFAULT false, evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(evidence)='object'),
 evidence_sha256 text CHECK(evidence_sha256 IS NULL OR evidence_sha256~'^[0-9a-f]{64}$'), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK((status<>'PASS') OR (evidence_sha256 IS NOT NULL AND ((certified_no_local_tax_assertion AND jurisdictions_expected IS NULL) OR (NOT certified_no_local_tax_assertion AND jurisdictions_expected IS NOT NULL AND jurisdictions_certified>=jurisdictions_expected AND (home_rule_expected IS NULL OR home_rule_certified>=home_rule_expected)))))
);

CREATE TABLE IF NOT EXISTS zsl_tax_acq.address_resolution_quality(
 state_code char(2) PRIMARY KEY REFERENCES zsl_tax_acq.jurisdiction_registry(state_code), status text NOT NULL CHECK(status IN('NOT_CERTIFIED','PASS','FAIL')),
 authoritative_address_rule_coverage_pct numeric CHECK(authoritative_address_rule_coverage_pct BETWEEN 0 AND 100), zip9_coverage_pct numeric CHECK(zip9_coverage_pct BETWEEN 0 AND 100),
 zip5_fallback_coverage_pct numeric CHECK(zip5_fallback_coverage_pct BETWEEN 0 AND 100), special_district_coverage_pct numeric CHECK(special_district_coverage_pct BETWEEN 0 AND 100),
 unresolved_address_pct numeric CHECK(unresolved_address_pct BETWEEN 0 AND 100), evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(evidence)='object'),
 evidence_sha256 text CHECK(evidence_sha256 IS NULL OR evidence_sha256~'^[0-9a-f]{64}$'), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(status<>'PASS' OR (evidence_sha256 IS NOT NULL AND unresolved_address_pct IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS zsl_tax_acq.family_coverage_attestations(
 state_code char(2) NOT NULL REFERENCES zsl_tax_acq.jurisdiction_registry(state_code),
 family text NOT NULL REFERENCES zsl_tax_acq.family_registry(family),
 status text NOT NULL CHECK(status IN('NOT_CERTIFIED','PASS','FAIL')),
 expected_object_count integer CHECK(expected_object_count IS NULL OR expected_object_count>=0),
 certified_object_count integer NOT NULL DEFAULT 0 CHECK(certified_object_count>=0),
 applicability_assertion_id uuid REFERENCES zsl_tax_acq.applicability_assertions(assertion_id),
 coverage_document jsonb NOT NULL CHECK(jsonb_typeof(coverage_document)='object'),
 evidence_sha256 text NOT NULL CHECK(evidence_sha256~'^[0-9a-f]{64}$'),
 evaluated_by text NOT NULL,
 evaluated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(state_code,family),
 CHECK(status<>'PASS' OR ((applicability_assertion_id IS NOT NULL) OR (expected_object_count IS NOT NULL AND expected_object_count>0 AND certified_object_count>=expected_object_count)))
);

ALTER TABLE zsl_tax_acq.address_resolution_quality ADD COLUMN IF NOT EXISTS test_address_count bigint;
ALTER TABLE zsl_tax_acq.address_resolution_quality ADD COLUMN IF NOT EXISTS resolved_address_count bigint;
ALTER TABLE zsl_tax_acq.address_resolution_quality ADD COLUMN IF NOT EXISTS unresolved_address_count bigint;
ALTER TABLE zsl_tax_acq.address_resolution_quality ADD COLUMN IF NOT EXISTS unresolved_threshold_pct numeric NOT NULL DEFAULT 0;
ALTER TABLE zsl_tax_acq.address_resolution_quality ADD COLUMN IF NOT EXISTS special_district_expected integer;
ALTER TABLE zsl_tax_acq.address_resolution_quality ADD COLUMN IF NOT EXISTS special_district_certified integer;
ALTER TABLE zsl_tax_acq.address_resolution_quality DROP CONSTRAINT IF EXISTS address_resolution_quality_pass_guard;
ALTER TABLE zsl_tax_acq.address_resolution_quality ADD CONSTRAINT address_resolution_quality_pass_guard CHECK(
 status<>'PASS' OR (
   evidence_sha256 IS NOT NULL AND test_address_count IS NOT NULL AND test_address_count>0 AND
   resolved_address_count IS NOT NULL AND unresolved_address_count IS NOT NULL AND
   resolved_address_count+unresolved_address_count=test_address_count AND
   unresolved_address_pct IS NOT NULL AND unresolved_address_pct<=unresolved_threshold_pct AND
   (special_district_expected IS NULL OR (special_district_certified IS NOT NULL AND special_district_certified>=special_district_expected))
 )
);

CREATE TABLE IF NOT EXISTS zsl_tax_acq.national_publication_runs(
 publication_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), publication_version text NOT NULL, status text NOT NULL CHECK(status IN('BUILDING','READY','CERTIFIED','FAILED','REVOKED','SUPERSEDED')),
 source_id uuid REFERENCES zsl.source_registry(source_id), release_id uuid REFERENCES zsl.source_releases(release_id), ingest_run_id uuid REFERENCES zsl.ingest_runs(ingest_run_id),
 artifact_id uuid REFERENCES zsl.source_artifacts(artifact_id), schema_validation_run_id uuid REFERENCES zsl.schema_validation_runs(schema_validation_run_id),
 reconciliation_run_id uuid REFERENCES zsl.reconciliation_runs(reconciliation_run_id), certification_run_id uuid REFERENCES zsl.certification_runs(certification_run_id),
 package_sha256 text NOT NULL CHECK(package_sha256~'^[0-9a-f]{64}$' AND package_sha256<>repeat('0',64)), git_sha text NOT NULL CHECK(git_sha~'^[0-9a-f]{7,64}$'),
 family_expected integer NOT NULL DEFAULT 1071 CHECK(family_expected=1071), family_certified integer NOT NULL DEFAULT 0, local_expected integer NOT NULL DEFAULT 51 CHECK(local_expected=51), local_certified integer NOT NULL DEFAULT 0,
 resolution_expected integer NOT NULL DEFAULT 51 CHECK(resolution_expected=51), resolution_certified integer NOT NULL DEFAULT 0, fatal_conflicts integer NOT NULL DEFAULT 0,
 publication_document jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(publication_document)='object'), publication_sha256 text CHECK(publication_sha256 IS NULL OR publication_sha256~'^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(), certified_at timestamptz
);

CREATE TABLE IF NOT EXISTS zsl_tax_acq.national_publication_memberships(
 publication_id uuid NOT NULL REFERENCES zsl_tax_acq.national_publication_runs(publication_id) ON DELETE RESTRICT, canonical_record_id uuid NOT NULL REFERENCES zsl_tax_acq.canonical_records(canonical_record_id) ON DELETE RESTRICT,
 state_code char(2) NOT NULL, family text NOT NULL, record_sha256 text NOT NULL CHECK(record_sha256~'^[0-9a-f]{64}$'), PRIMARY KEY(publication_id,canonical_record_id)
);
CREATE INDEX IF NOT EXISTS ix_zsl_tax_pub_member_cell ON zsl_tax_acq.national_publication_memberships(publication_id,state_code,family);

CREATE TABLE IF NOT EXISTS zsl_tax_acq.national_family_coverage(
 publication_id uuid NOT NULL REFERENCES zsl_tax_acq.national_publication_runs(publication_id) ON DELETE RESTRICT, state_code char(2) NOT NULL, family text NOT NULL,
 status text NOT NULL CHECK(status IN('CERTIFIED','CERTIFIED_NOT_APPLICABLE','MISSING','CONFLICTED')), evidence_count integer NOT NULL DEFAULT 0, applicability_assertion_id uuid REFERENCES zsl_tax_acq.applicability_assertions(assertion_id),
 evidence_sha256 text CHECK(evidence_sha256 IS NULL OR evidence_sha256~'^[0-9a-f]{64}$'), PRIMARY KEY(publication_id,state_code,family),
 CHECK((status IN('CERTIFIED','CERTIFIED_NOT_APPLICABLE') AND evidence_sha256 IS NOT NULL) OR status IN('MISSING','CONFLICTED'))
);
CREATE TABLE IF NOT EXISTS zsl_tax_acq.national_local_coverage(
 publication_id uuid NOT NULL REFERENCES zsl_tax_acq.national_publication_runs(publication_id), state_code char(2) NOT NULL, status text NOT NULL CHECK(status IN('PASS','FAIL')), evidence_sha256 text NOT NULL CHECK(evidence_sha256~'^[0-9a-f]{64}$'), PRIMARY KEY(publication_id,state_code));
CREATE TABLE IF NOT EXISTS zsl_tax_acq.national_resolution_coverage(
 publication_id uuid NOT NULL REFERENCES zsl_tax_acq.national_publication_runs(publication_id), state_code char(2) NOT NULL, status text NOT NULL CHECK(status IN('PASS','FAIL')), unresolved_address_pct numeric, evidence_sha256 text NOT NULL CHECK(evidence_sha256~'^[0-9a-f]{64}$'), PRIMARY KEY(publication_id,state_code));

COMMIT;
