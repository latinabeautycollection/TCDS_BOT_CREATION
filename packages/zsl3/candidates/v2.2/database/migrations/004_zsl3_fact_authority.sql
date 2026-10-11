BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
CREATE TABLE IF NOT EXISTS zsl.zsl3_source_facts(
  fact_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id) ON DELETE RESTRICT,
  location_id uuid NOT NULL REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  feature_code text NOT NULL,
  numeric_value numeric,text_value text,
  unit text NOT NULL,evidence_class text NOT NULL CHECK(evidence_class='SOURCE_FACT'),
  source_role text NOT NULL CHECK(source_role IN('ACS','BEA_RPP','CBP','ZBP')),
  source_binding_id uuid NOT NULL REFERENCES zsl.zsl3_source_bindings(source_binding_id),
  source_record_id uuid NOT NULL,source_record_sha256 text NOT NULL CHECK(source_record_sha256 ~ '^[0-9a-f]{64}$'),
  source_variable_code text,source_vintage text NOT NULL,
  geography_scope text NOT NULL CHECK(geography_scope IN('STATE','COUNTY','PLACE','ZCTA','POSTAL_CODE','MSA')),
  source_geography_type text NOT NULL,
  missingness_state text NOT NULL DEFAULT 'PRESENT' CHECK(missingness_state IN('PRESENT','MISSING','UNAVAILABLE','SUPPRESSED','NOT_APPLICABLE','CONFLICTED','DERIVED_FROM_PARENT','INVALID_SOURCE_VALUE')),
  suppression_flag text,
  fact_document jsonb NOT NULL CHECK(jsonb_typeof(fact_document)='object'), fact_sha256 text NOT NULL CHECK(fact_sha256 ~ '^[0-9a-f]{64}$'),created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(((numeric_value IS NOT NULL)::int+(text_value IS NOT NULL)::int=1) OR missingness_state IN('MISSING','UNAVAILABLE','SUPPRESSED','NOT_APPLICABLE','CONFLICTED','INVALID_SOURCE_VALUE'))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_zsl3_source_fact_identity ON zsl.zsl3_source_facts(build_run_id,location_id,feature_code,source_binding_id,COALESCE(source_variable_code,''),source_record_id);
CREATE INDEX IF NOT EXISTS ix_zsl3_fact_loc_feature ON zsl.zsl3_source_facts(build_run_id,location_id,feature_code);
CREATE INDEX IF NOT EXISTS ix_zsl3_fact_binding ON zsl.zsl3_source_facts(build_run_id,source_binding_id);

CREATE TABLE IF NOT EXISTS zsl.zsl3_fact_lineage(
 lineage_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
 fact_id uuid NOT NULL REFERENCES zsl.zsl3_source_facts(fact_id),source_binding_id uuid NOT NULL REFERENCES zsl.zsl3_source_bindings(source_binding_id),
 source_release_id uuid NOT NULL,ingest_run_id uuid NOT NULL,certification_run_id uuid NOT NULL,raw_record_id uuid NOT NULL,raw_record_sha256 text NOT NULL CHECK(raw_record_sha256 ~ '^[0-9a-f]{64}$'),
 lineage_document jsonb NOT NULL CHECK(jsonb_typeof(lineage_document)='object'),lineage_sha256 text NOT NULL CHECK(lineage_sha256 ~ '^[0-9a-f]{64}$'),created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(build_run_id,fact_id,raw_record_id)
);

CREATE TABLE IF NOT EXISTS zsl.zsl3_regional_price_parity_facts(
 fact_id uuid PRIMARY KEY REFERENCES zsl.zsl3_source_facts(fact_id),year integer NOT NULL CHECK(year BETWEEN 2000 AND 2200),
 bea_geography_identifier text NOT NULL,bea_geography_kind text NOT NULL CHECK(bea_geography_kind IN('STATE','MSA')),
 table_name text NOT NULL,line_code text NOT NULL,rpp numeric NOT NULL CHECK(rpp>0 AND rpp<500),
 msa_mapping_status text NOT NULL DEFAULT 'NOT_APPLICABLE' CHECK(msa_mapping_status IN('NOT_APPLICABLE','AUTHORITATIVE','PENDING_AUTHORITATIVE_METRO_MAPPING'))
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_business_activity_facts(
 fact_id uuid PRIMARY KEY REFERENCES zsl.zsl3_source_facts(fact_id),source_naics_vocabulary text NOT NULL,normalized_naics_vocabulary text NOT NULL,naics_code text NOT NULL,
 establishment_count bigint CHECK(establishment_count IS NULL OR establishment_count>=0),employment bigint CHECK(employment IS NULL OR employment>=0),annual_payroll numeric CHECK(annual_payroll IS NULL OR annual_payroll>=0),
 establishment_flag text,employment_flag text,payroll_flag text
);

CREATE TABLE IF NOT EXISTS zsl.zsl3_bea_msa_reconciliation(
 reconciliation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
 source_binding_id uuid NOT NULL REFERENCES zsl.zsl3_source_bindings(source_binding_id),
 raw_record_id uuid NOT NULL, raw_record_sha256 text NOT NULL CHECK(raw_record_sha256 ~ '^[0-9a-f]{64}$'),
 bea_geography_code text NOT NULL, bea_geography_name text,
 mapping_status text NOT NULL CHECK(mapping_status IN('MAPPED_AUTHORITATIVE_CBSA','MAPPED_AUTHORITATIVE_METDIV','PENDING_ZSL2_AUTHORITY','UNRESOLVED','REJECTED')),
 resolved_location_id uuid REFERENCES zsl.locations(location_id), reason_code text NOT NULL,
 evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'), evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(build_run_id,source_binding_id,raw_record_id)
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_conflicts(
 conflict_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
 severity text NOT NULL CHECK(severity IN('INFO','WARN','FATAL')), conflict_code text NOT NULL, location_id uuid,
 evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'), evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now()
);
COMMIT;
