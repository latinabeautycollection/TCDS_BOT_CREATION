BEGIN;
CREATE TABLE IF NOT EXISTS zsl.zsl5_runtime_population_runs_v14(
 population_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 build_run_id uuid NOT NULL REFERENCES zsl.zsl5_build_runs(build_run_id) ON DELETE RESTRICT,
 publication_id uuid NOT NULL REFERENCES zsl_tax_acq.national_publication_runs(publication_id) ON DELETE RESTRICT,
 status text NOT NULL CHECK(status IN('CREATED','LOADING','LOADED','VALIDATING','PASS','FAIL')),
 expected_family_bindings integer NOT NULL DEFAULT 21 CHECK(expected_family_bindings=21),
 actual_family_bindings integer NOT NULL DEFAULT 0 CHECK(actual_family_bindings BETWEEN 0 AND 21),
 expected_categories integer NOT NULL DEFAULT 8 CHECK(expected_categories=8),
 actual_categories integer NOT NULL DEFAULT 0 CHECK(actual_categories BETWEEN 0 AND 8),
 loaded_fact_count bigint NOT NULL DEFAULT 0 CHECK(loaded_fact_count>=0),
 loaded_assertion_count bigint NOT NULL DEFAULT 0 CHECK(loaded_assertion_count>=0),
 evidence_document jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(evidence_document)='object'),
 evidence_sha256 text,
 started_at timestamptz NOT NULL DEFAULT now(),completed_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_zsl5_runtime_population_build_pub ON zsl.zsl5_runtime_population_runs_v14(build_run_id,publication_id);
COMMIT;
