BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
CREATE TABLE IF NOT EXISTS zsl.zsl3_feature_definitions(
 feature_definition_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
 feature_code text NOT NULL,formula_version text NOT NULL,formula_type text NOT NULL,input_feature_codes text[] NOT NULL,
 formula_document jsonb NOT NULL CHECK(jsonb_typeof(formula_document)='object'),parameters_json jsonb NOT NULL DEFAULT '{}'::jsonb,
 formula_sha256 text NOT NULL CHECK(formula_sha256 ~ '^[0-9a-f]{64}$'),minimum_inputs integer NOT NULL DEFAULT 1 CHECK(minimum_inputs>0),minimum_sample_size integer NOT NULL DEFAULT 1 CHECK(minimum_sample_size>0),enabled boolean NOT NULL DEFAULT true,
 UNIQUE(build_run_id,feature_code,formula_version)
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_derived_features(
 derived_feature_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),location_id uuid NOT NULL REFERENCES zsl.locations(location_id),
 feature_definition_id uuid NOT NULL REFERENCES zsl.zsl3_feature_definitions(feature_definition_id),feature_code text NOT NULL,numeric_value numeric,unit text NOT NULL,
 evidence_class text NOT NULL CHECK(evidence_class='DERIVED_FEATURE'),derivation_scope text NOT NULL CHECK(derivation_scope IN('DIRECT_GRAIN','PERCENTILE_WITHIN_GRAIN','DERIVED_FROM_PARENT')),
 source_vintage_set jsonb NOT NULL CHECK(jsonb_typeof(source_vintage_set)='object'),derivation_document jsonb NOT NULL CHECK(jsonb_typeof(derivation_document)='object'),derivation_sha256 text NOT NULL CHECK(derivation_sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(build_run_id,location_id,feature_code)
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_feature_lineage(
 feature_lineage_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),derived_feature_id uuid NOT NULL REFERENCES zsl.zsl3_derived_features(derived_feature_id),
 input_type text NOT NULL CHECK(input_type IN('SOURCE_FACT','DERIVED_FEATURE')),input_fact_id uuid REFERENCES zsl.zsl3_source_facts(fact_id),input_derived_feature_id uuid REFERENCES zsl.zsl3_derived_features(derived_feature_id),
 input_sha256 text NOT NULL CHECK(input_sha256 ~ '^[0-9a-f]{64}$'),formula_definition_id uuid NOT NULL REFERENCES zsl.zsl3_feature_definitions(feature_definition_id),formula_sha256 text NOT NULL CHECK(formula_sha256 ~ '^[0-9a-f]{64}$'),
 lineage_document jsonb NOT NULL CHECK(jsonb_typeof(lineage_document)='object'),lineage_sha256 text NOT NULL CHECK(lineage_sha256 ~ '^[0-9a-f]{64}$'),created_at timestamptz NOT NULL DEFAULT now(),
 CHECK((input_fact_id IS NOT NULL)::int+(input_derived_feature_id IS NOT NULL)::int=1)
);
CREATE INDEX IF NOT EXISTS ix_zsl3_derived_loc_feature ON zsl.zsl3_derived_features(build_run_id,location_id,feature_code);
COMMIT;
