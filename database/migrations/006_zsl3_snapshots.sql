BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
CREATE TABLE IF NOT EXISTS zsl.zsl3_geographic_feature_snapshots(
 snapshot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
 location_id uuid NOT NULL REFERENCES zsl.locations(location_id),
 source_vintage_set jsonb NOT NULL CHECK(jsonb_typeof(source_vintage_set)='object' AND source_vintage_set<>'{}'::jsonb),
 formula_registry_sha256 text NOT NULL CHECK(formula_registry_sha256 ~ '^[0-9a-f]{64}$'),
 policy_sha256 text NOT NULL CHECK(policy_sha256 ~ '^[0-9a-f]{64}$'),
 expected_source_fact_count integer NOT NULL DEFAULT 0 CHECK(expected_source_fact_count>=0),
 actual_source_fact_count integer NOT NULL DEFAULT 0 CHECK(actual_source_fact_count>=0),
 expected_derived_feature_count integer NOT NULL DEFAULT 0 CHECK(expected_derived_feature_count>=0),
 actual_derived_feature_count integer NOT NULL DEFAULT 0 CHECK(actual_derived_feature_count>=0),
 required_sources_expected integer NOT NULL DEFAULT 0 CHECK(required_sources_expected>=0),
 required_sources_present integer NOT NULL DEFAULT 0 CHECK(required_sources_present>=0),
 source_coverage_pct numeric NOT NULL DEFAULT 0 CHECK(source_coverage_pct BETWEEN 0 AND 100),
 source_fact_coverage_pct numeric NOT NULL DEFAULT 0 CHECK(source_fact_coverage_pct BETWEEN 0 AND 100),
 derived_feature_coverage_pct numeric NOT NULL DEFAULT 0 CHECK(derived_feature_coverage_pct BETWEEN 0 AND 100),
 overall_feature_coverage_pct numeric NOT NULL DEFAULT 0 CHECK(overall_feature_coverage_pct BETWEEN 0 AND 100),
 location_coverage_pct numeric NOT NULL DEFAULT 0 CHECK(location_coverage_pct BETWEEN 0 AND 100),
 snapshot_document jsonb NOT NULL CHECK(jsonb_typeof(snapshot_document)='object'),
 snapshot_sha256 text NOT NULL CHECK(snapshot_sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(build_run_id,location_id)
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_geographic_feature_snapshot_values(
 snapshot_value_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 snapshot_id uuid NOT NULL REFERENCES zsl.zsl3_geographic_feature_snapshots(snapshot_id),
 build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
 location_id uuid NOT NULL REFERENCES zsl.locations(location_id),
 feature_code text NOT NULL,numeric_value numeric,text_value text,unit text NOT NULL,
 evidence_class text NOT NULL CHECK(evidence_class IN('SOURCE_FACT','DERIVED_FEATURE')),
 missingness_state text NOT NULL CHECK(missingness_state IN('PRESENT','MISSING','UNAVAILABLE','SUPPRESSED','NOT_APPLICABLE','CONFLICTED','DERIVED_FROM_PARENT','INVALID_SOURCE_VALUE')),
 freshness_policy_id text NOT NULL,age_days integer,
 freshness_status text NOT NULL CHECK(freshness_status IN('CURRENT','AGING','STALE','EXPIRED','UNKNOWN')),
 confidence_score numeric NOT NULL CHECK(confidence_score BETWEEN 0 AND 1),
 confidence_label text NOT NULL CHECK(confidence_label IN('HIGH','MEDIUM','LOW','INSUFFICIENT')),
 source_object_id uuid NOT NULL,source_object_sha256 text NOT NULL CHECK(source_object_sha256 ~ '^[0-9a-f]{64}$'),
 value_document jsonb NOT NULL CHECK(jsonb_typeof(value_document)='object'),
 value_sha256 text NOT NULL CHECK(value_sha256 ~ '^[0-9a-f]{64}$'),created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(snapshot_id,feature_code,source_object_id)
);
CREATE INDEX IF NOT EXISTS ix_zsl3_snapshot_values_current ON zsl.zsl3_geographic_feature_snapshot_values(build_run_id,location_id,feature_code);
COMMIT;
