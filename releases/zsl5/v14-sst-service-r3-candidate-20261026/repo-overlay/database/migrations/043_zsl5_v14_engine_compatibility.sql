-- TCDS 043: ZSL5 v1.4 compatibility + comprehensive 21-family runtime
BEGIN;
DO $$ BEGIN IF to_regclass('zsl.zsl5_build_runs') IS NULL OR to_regclass('zsl.zsl5_certification_runs') IS NULL THEN RAISE EXCEPTION 'ZSL5_V12_BASELINE_REQUIRED'; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl5_reader') THEN CREATE ROLE zsl5_reader NOLOGIN; END IF; IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl5_builder') THEN CREATE ROLE zsl5_builder NOLOGIN; END IF; IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl5_certifier') THEN CREATE ROLE zsl5_certifier NOLOGIN; END IF; IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl5_admin') THEN CREATE ROLE zsl5_admin NOLOGIN; END IF; END $$;
GRANT USAGE ON SCHEMA zsl TO zsl5_reader,zsl5_builder,zsl5_certifier,zsl5_admin;
ALTER TABLE zsl.zsl5_build_runs DROP CONSTRAINT IF EXISTS zsl5_build_runs_engine_version_check;
ALTER TABLE zsl.zsl5_build_runs ADD CONSTRAINT zsl5_build_runs_engine_version_check CHECK(engine_version IN('zsl5-v1.2.0','zsl5-v1.4.0'));
ALTER TABLE zsl.zsl5_certification_runs DROP CONSTRAINT IF EXISTS zsl5_certification_runs_engine_version_check;
ALTER TABLE zsl.zsl5_certification_runs ADD CONSTRAINT zsl5_certification_runs_engine_version_check CHECK(engine_version IN('zsl5-v1.2.0','zsl5-v1.4.0'));
ALTER TABLE zsl.zsl5_build_runs ADD COLUMN IF NOT EXISTS national_tax_publication_sha256 text;
ALTER TABLE zsl.zsl5_build_runs ADD COLUMN IF NOT EXISTS family_policy_sha256 text;
ALTER TABLE zsl.zsl5_build_runs ADD COLUMN IF NOT EXISTS allocation_policy_sha256 text;
ALTER TABLE zsl.zsl5_build_runs ADD COLUMN IF NOT EXISTS fee_policy_sha256 text;

CREATE TABLE IF NOT EXISTS zsl.zsl5_national_publication_bindings_v14(
 build_run_id uuid PRIMARY KEY REFERENCES zsl.zsl5_build_runs(build_run_id) ON DELETE RESTRICT, publication_id uuid NOT NULL REFERENCES zsl_tax_acq.national_publication_runs(publication_id),
 release_id uuid NOT NULL REFERENCES zsl.source_releases(release_id), ingest_run_id uuid NOT NULL REFERENCES zsl.ingest_runs(ingest_run_id), certification_run_id uuid NOT NULL REFERENCES zsl.certification_runs(certification_run_id),
 publication_sha256 text NOT NULL CHECK(publication_sha256~'^[0-9a-f]{64}$'), binding_document jsonb NOT NULL CHECK(jsonb_typeof(binding_document)='object'), binding_sha256 text NOT NULL CHECK(binding_sha256~'^[0-9a-f]{64}$'), created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS zsl.zsl5_tax_product_mappings_v14(
 mapping_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),build_run_id uuid NOT NULL REFERENCES zsl.zsl5_build_runs(build_run_id),
 tcds_category_code text NOT NULL,tax_product_class text NOT NULL,tax_product_subclass text,
 attribute_predicate jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(attribute_predicate)='object'),
 mapping_confidence numeric(6,5) NOT NULL CHECK(mapping_confidence BETWEEN 0 AND 1),mapping_version text NOT NULL,
 mapping_document jsonb NOT NULL CHECK(jsonb_typeof(mapping_document)='object'),mapping_sha256 text NOT NULL CHECK(mapping_sha256~'^[0-9a-f]{64}$'),enabled boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_zsl5_v14_tax_product_mapping ON zsl.zsl5_tax_product_mappings_v14(build_run_id,tcds_category_code,tax_product_class,COALESCE(tax_product_subclass,''),mapping_version);

CREATE TABLE IF NOT EXISTS zsl.zsl5_family_facts_v14(
 fact_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), build_run_id uuid NOT NULL REFERENCES zsl.zsl5_build_runs(build_run_id), family text NOT NULL CHECK(family IN('TAX_REGIME','TAX_JURISDICTION','TAX_JURISDICTION_ASSIGNMENT','STATE_RATE','LOCAL_RATE','RATE_COMPONENT_RULE','RATE_CAP_THRESHOLD_RULE','PRODUCT_TAXABILITY','TAXABLE_BASE_RULE','BUNDLED_TRANSACTION_RULE','ALLOCATION_RULE','TAX_HOLIDAY','SOURCING_RULE','SELLER_COLLECTION_RULE','MARKETPLACE_RULE','SELLER_TAX_ELECTION','EXEMPTION_RULE','EXEMPTION_CERTIFICATE_REQUIREMENT','TAX_CREDIT_RULE','ROUNDING_RULE','MANDATORY_TRANSACTION_FEE')), state_code char(2) NOT NULL,
 tax_jurisdiction_code text, tax_product_class text, tax_product_subclass text, purchase_channel text, effective_from timestamptz, effective_to timestamptz, priority integer NOT NULL DEFAULT 100,
 predicate_document jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(predicate_document)='object'), value_document jsonb NOT NULL CHECK(jsonb_typeof(value_document)='object'),
 source_binding_id uuid NOT NULL REFERENCES zsl.zsl5_source_bindings(source_binding_id), canonical_record_id uuid NOT NULL REFERENCES zsl_tax_acq.canonical_records(canonical_record_id), raw_record_id uuid NOT NULL REFERENCES zsl_raw.raw_records(record_id),
 raw_record_sha256 text NOT NULL CHECK(raw_record_sha256~'^[0-9a-f]{64}$'), fact_sha256 text NOT NULL CHECK(fact_sha256~'^[0-9a-f]{64}$'), created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(effective_to IS NULL OR effective_from IS NULL OR effective_to>=effective_from), UNIQUE(build_run_id,canonical_record_id)
);
CREATE INDEX IF NOT EXISTS ix_zsl5_v14_family_lookup ON zsl.zsl5_family_facts_v14(build_run_id,family,state_code,effective_from,effective_to);
CREATE INDEX IF NOT EXISTS ix_zsl5_v14_juris_lookup ON zsl.zsl5_family_facts_v14(build_run_id,family,state_code,tax_jurisdiction_code);

CREATE TABLE IF NOT EXISTS zsl.zsl5_applicability_assertions_v14(
 assertion_id uuid PRIMARY KEY, build_run_id uuid NOT NULL REFERENCES zsl.zsl5_build_runs(build_run_id), state_code char(2) NOT NULL, family text NOT NULL CHECK(family IN('TAX_REGIME','TAX_JURISDICTION','TAX_JURISDICTION_ASSIGNMENT','STATE_RATE','LOCAL_RATE','RATE_COMPONENT_RULE','RATE_CAP_THRESHOLD_RULE','PRODUCT_TAXABILITY','TAXABLE_BASE_RULE','BUNDLED_TRANSACTION_RULE','ALLOCATION_RULE','TAX_HOLIDAY','SOURCING_RULE','SELLER_COLLECTION_RULE','MARKETPLACE_RULE','SELLER_TAX_ELECTION','EXEMPTION_RULE','EXEMPTION_CERTIFICATE_REQUIREMENT','TAX_CREDIT_RULE','ROUNDING_RULE','MANDATORY_TRANSACTION_FEE')), assertion text NOT NULL,
 source_assertion_id uuid NOT NULL REFERENCES zsl_tax_acq.applicability_assertions(assertion_id), effective_from timestamptz,effective_to timestamptz,evidence jsonb NOT NULL,evidence_sha256 text NOT NULL CHECK(evidence_sha256~'^[0-9a-f]{64}$'), UNIQUE(build_run_id,state_code,family,source_assertion_id)
);

CREATE TABLE IF NOT EXISTS zsl.zsl5_quote_transactions_v14(
 transaction_id uuid PRIMARY KEY,build_run_id uuid NOT NULL REFERENCES zsl.zsl5_build_runs(build_run_id),external_correlation_id text,transaction_datetime timestamptz NOT NULL,evaluation_as_of timestamptz NOT NULL,purchase_channel text NOT NULL,
 seller_context jsonb NOT NULL,buyer_tax_profile jsonb NOT NULL,location_context jsonb NOT NULL,input_document jsonb NOT NULL,input_sha256 text NOT NULL CHECK(input_sha256~'^[0-9a-f]{64}$'),created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS zsl.zsl5_quote_line_items_v14(
 transaction_id uuid NOT NULL REFERENCES zsl.zsl5_quote_transactions_v14(transaction_id),line_id text NOT NULL,sku text NOT NULL,quantity integer NOT NULL CHECK(quantity>0),unit_price_cents bigint NOT NULL CHECK(unit_price_cents>=0),tcds_category_code text NOT NULL,tax_product_class text NOT NULL,tax_product_subclass text,tax_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,PRIMARY KEY(transaction_id,line_id));
CREATE TABLE IF NOT EXISTS zsl.zsl5_quote_adjustments_v14(
 adjustment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),transaction_id uuid NOT NULL REFERENCES zsl.zsl5_quote_transactions_v14(transaction_id),line_id text,adjustment_kind text NOT NULL CHECK(adjustment_kind IN('CHARGE','DISCOUNT','PRIOR_TAX')),component_type text NOT NULL,amount_cents bigint NOT NULL CHECK(amount_cents>=0),adjustment_document jsonb NOT NULL DEFAULT '{}'::jsonb);
CREATE TABLE IF NOT EXISTS zsl.zsl5_tax_quote_evidence_v14(
 quote_evidence_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),transaction_id uuid NOT NULL REFERENCES zsl.zsl5_quote_transactions_v14(transaction_id),build_run_id uuid NOT NULL REFERENCES zsl.zsl5_build_runs(build_run_id),evaluation_as_of timestamptz NOT NULL,
 state_code char(2) NOT NULL,jurisdiction_codes text[] NOT NULL,taxable_base_cents bigint NOT NULL CHECK(taxable_base_cents>=0),checkout_tax_estimate_cents bigint,estimated_legal_tax_burden_cents bigint NOT NULL CHECK(estimated_legal_tax_burden_cents>=0),potential_use_tax_cents bigint NOT NULL CHECK(potential_use_tax_cents>=0),mandatory_government_fees_cents bigint NOT NULL CHECK(mandatory_government_fees_cents>=0),total_government_acquisition_cost_cents bigint NOT NULL CHECK(total_government_acquisition_cost_cents>=0),
 component_ledger jsonb NOT NULL,taxable_base_ledger jsonb NOT NULL,sourcing_ledger jsonb NOT NULL,collection_ledger jsonb NOT NULL,marketplace_ledger jsonb NOT NULL,election_ledger jsonb NOT NULL,bundle_ledger jsonb NOT NULL,allocation_ledger jsonb NOT NULL,exemption_ledger jsonb NOT NULL,holiday_ledger jsonb NOT NULL,cap_ledger jsonb NOT NULL,credit_ledger jsonb NOT NULL,fee_ledger jsonb NOT NULL,rounding_ledger jsonb NOT NULL,
 confidence_score numeric(6,5) NOT NULL CHECK(confidence_score BETWEEN 0 AND 1),confidence_label text NOT NULL CHECK(confidence_label IN('HIGH','MEDIUM','LOW','INSUFFICIENT')),missingness_status text NOT NULL,source_fact_ids uuid[] NOT NULL,evidence_document jsonb NOT NULL,evidence_sha256 text NOT NULL CHECK(evidence_sha256~'^[0-9a-f]{64}$'),created_at timestamptz NOT NULL DEFAULT now());

CREATE OR REPLACE FUNCTION zsl.zsl5_v14_reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'ZSL5_V14_IMMUTABLE_HISTORY'; END $$;
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['zsl5_national_publication_bindings_v14','zsl5_tax_product_mappings_v14','zsl5_family_facts_v14','zsl5_applicability_assertions_v14','zsl5_tax_quote_evidence_v14'] LOOP EXECUTE format('DROP TRIGGER IF EXISTS %I ON zsl.%I','trg_'||t||'_immutable',t); EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON zsl.%I FOR EACH ROW EXECUTE FUNCTION zsl.zsl5_v14_reject_mutation()','trg_'||t||'_immutable',t); END LOOP; END $$;
GRANT SELECT ON zsl.zsl5_national_publication_bindings_v14,zsl.zsl5_tax_product_mappings_v14,zsl.zsl5_family_facts_v14,zsl.zsl5_applicability_assertions_v14,zsl.zsl5_tax_quote_evidence_v14 TO zsl5_reader,zsl5_certifier;
GRANT SELECT,INSERT ON zsl.zsl5_national_publication_bindings_v14,zsl.zsl5_tax_product_mappings_v14,zsl.zsl5_family_facts_v14,zsl.zsl5_applicability_assertions_v14,zsl.zsl5_quote_transactions_v14,zsl.zsl5_quote_line_items_v14,zsl.zsl5_quote_adjustments_v14,zsl.zsl5_tax_quote_evidence_v14 TO zsl5_builder;
GRANT SELECT,INSERT,UPDATE,DELETE ON zsl.zsl5_national_publication_bindings_v14,zsl.zsl5_tax_product_mappings_v14,zsl.zsl5_family_facts_v14,zsl.zsl5_applicability_assertions_v14,zsl.zsl5_quote_transactions_v14,zsl.zsl5_quote_line_items_v14,zsl.zsl5_quote_adjustments_v14,zsl.zsl5_tax_quote_evidence_v14 TO zsl5_admin;
COMMIT;
