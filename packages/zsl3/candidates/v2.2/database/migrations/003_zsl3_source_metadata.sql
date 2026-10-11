BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
CREATE TABLE IF NOT EXISTS zsl.zsl3_acs_variable_metadata(
  metadata_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
  source_binding_id uuid NOT NULL REFERENCES zsl.zsl3_source_bindings(source_binding_id), dataset text NOT NULL, vintage text NOT NULL,
  variable_group text, variable_code text NOT NULL, label text NOT NULL, concept text, predicate_type text, unit text,
  geography_applicability text[] NOT NULL DEFAULT '{}', metadata_document jsonb NOT NULL CHECK(jsonb_typeof(metadata_document)='object'),
  metadata_sha256 text NOT NULL CHECK(metadata_sha256 ~ '^[0-9a-f]{64}$'),
  source_release_id uuid NOT NULL, ingest_run_id uuid NOT NULL, artifact_id uuid NOT NULL, schema_validation_run_id uuid NOT NULL,
  zsl1_validation_document_sha256 text NOT NULL CHECK(zsl1_validation_document_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(build_run_id,source_binding_id,variable_code)
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_acs_variable_sets(
  variable_set_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
  set_code text NOT NULL, definition jsonb NOT NULL CHECK(jsonb_typeof(definition)='object'), definition_sha256 text NOT NULL CHECK(definition_sha256 ~ '^[0-9a-f]{64}$'), created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(build_run_id,set_code)
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_acs_geography_profiles(
  geography_profile_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
  source_geography text NOT NULL, canonical_location_type text NOT NULL, definition jsonb NOT NULL CHECK(jsonb_typeof(definition)='object'), definition_sha256 text NOT NULL CHECK(definition_sha256 ~ '^[0-9a-f]{64}$'), created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(build_run_id,source_geography)
);

CREATE TABLE IF NOT EXISTS zsl.zsl3_naics_vocabularies(
  vocabulary_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id), vocabulary_code text NOT NULL,
  authority text NOT NULL, definition jsonb NOT NULL CHECK(jsonb_typeof(definition)='object'), definition_sha256 text NOT NULL CHECK(definition_sha256 ~ '^[0-9a-f]{64}$'), created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(build_run_id,vocabulary_code)
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_naics_codes(
  vocabulary_id uuid NOT NULL REFERENCES zsl.zsl3_naics_vocabularies(vocabulary_id), naics_code text NOT NULL, title text,
  definition jsonb NOT NULL DEFAULT '{}'::jsonb, definition_sha256 text NOT NULL CHECK(definition_sha256 ~ '^[0-9a-f]{64}$'), PRIMARY KEY(vocabulary_id,naics_code)
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_naics_crosswalks(
  crosswalk_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
  source_vocabulary text NOT NULL,target_vocabulary text NOT NULL,source_code text NOT NULL,target_code text NOT NULL,
  authority text NOT NULL,crosswalk_document jsonb NOT NULL CHECK(jsonb_typeof(crosswalk_document)='object'),crosswalk_sha256 text NOT NULL CHECK(crosswalk_sha256 ~ '^[0-9a-f]{64}$'), certified boolean NOT NULL DEFAULT false,
  UNIQUE(build_run_id,source_vocabulary,target_vocabulary,source_code,target_code)
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_naics_feature_groups(
  build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id), group_code text NOT NULL,target_vocabulary text NOT NULL,
  definition jsonb NOT NULL CHECK(jsonb_typeof(definition)='object'),definition_sha256 text NOT NULL CHECK(definition_sha256 ~ '^[0-9a-f]{64}$'),PRIMARY KEY(build_run_id,group_code)
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_naics_feature_group_members(
  build_run_id uuid NOT NULL,group_code text NOT NULL,naics_code text NOT NULL,PRIMARY KEY(build_run_id,group_code,naics_code),
  FOREIGN KEY(build_run_id,group_code) REFERENCES zsl.zsl3_naics_feature_groups(build_run_id,group_code)
);
COMMIT;
