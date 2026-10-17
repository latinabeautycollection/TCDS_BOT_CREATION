BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
CREATE TABLE IF NOT EXISTS zsl.zsl3_runtime_check_runs(
 runtime_check_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
 package_sha256 text NOT NULL CHECK(package_sha256 ~ '^[0-9a-f]{64}$'),
 policy_sha256 text NOT NULL CHECK(policy_sha256 ~ '^[0-9a-f]{64}$'),
 started_at timestamptz NOT NULL DEFAULT now(), completed_at timestamptz,
 status text NOT NULL CHECK(status IN('RUNNING','PASS','FAIL')),
 evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(evidence)='object'),
 evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$')
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_runtime_checks(
 runtime_check_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 runtime_check_run_id uuid NOT NULL REFERENCES zsl.zsl3_runtime_check_runs(runtime_check_run_id),
 build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
 check_code text NOT NULL,status text NOT NULL CHECK(status IN('PASS','FAIL','NOT_EXECUTED')),
 checked_count bigint NOT NULL DEFAULT 0,failed_count bigint NOT NULL DEFAULT 0,
 expected_value jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(expected_value) IN('object','array')),
 actual_value jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(actual_value) IN('object','array')),
 evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'),
 evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(runtime_check_run_id,check_code)
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_qa_evidence(
 qa_evidence_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
 evidence_code text NOT NULL,status text NOT NULL CHECK(status IN('PASS','FAIL')),evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'),
 evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),actor text NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_certification_runs(
 certification_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
 runtime_check_run_id uuid NOT NULL REFERENCES zsl.zsl3_runtime_check_runs(runtime_check_run_id),
 status text NOT NULL CHECK(status IN('PENDING','CERTIFIED','FAILED','REVOKED','SUPERSEDED')),
 engine_version text NOT NULL CHECK(engine_version='zsl3-v2.2.0'),
 package_sha256 text NOT NULL CHECK(package_sha256 ~ '^[0-9a-f]{64}$'),git_sha text NOT NULL,
 source_manifest_sha256 text NOT NULL CHECK(source_manifest_sha256 ~ '^[0-9a-f]{64}$'),
 migration_manifest_sha256 text NOT NULL CHECK(migration_manifest_sha256 ~ '^[0-9a-f]{64}$'),
 dependency_tree_sha256 text NOT NULL CHECK(dependency_tree_sha256 ~ '^[0-9a-f]{64}$'),
 source_policy_sha256 text NOT NULL CHECK(source_policy_sha256 ~ '^[0-9a-f]{64}$'),
 feature_policy_sha256 text NOT NULL CHECK(feature_policy_sha256 ~ '^[0-9a-f]{64}$'),
 confidence_policy_sha256 text NOT NULL CHECK(confidence_policy_sha256 ~ '^[0-9a-f]{64}$'),
 freshness_policy_sha256 text NOT NULL CHECK(freshness_policy_sha256 ~ '^[0-9a-f]{64}$'),
 naics_policy_sha256 text NOT NULL CHECK(naics_policy_sha256 ~ '^[0-9a-f]{64}$'),
 certification_policy_sha256 text NOT NULL CHECK(certification_policy_sha256 ~ '^[0-9a-f]{64}$'),
 feature_registry_sha256 text NOT NULL CHECK(feature_registry_sha256 ~ '^[0-9a-f]{64}$'),
 evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'),
 evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
 certifier_actor text NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),certified_at timestamptz
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_authority_events(
 authority_event_id bigserial PRIMARY KEY,event_type text NOT NULL CHECK(event_type IN('ACTIVATED','REVOKED')),
 build_run_id uuid NOT NULL REFERENCES zsl.zsl3_build_runs(build_run_id),
 certification_run_id uuid NOT NULL REFERENCES zsl.zsl3_certification_runs(certification_run_id),
 actor text NOT NULL,evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'),
 evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS zsl.zsl3_authority_state(
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),build_run_id uuid REFERENCES zsl.zsl3_build_runs(build_run_id),
 certification_run_id uuid REFERENCES zsl.zsl3_certification_runs(certification_run_id),
 authority_event_id bigint REFERENCES zsl.zsl3_authority_events(authority_event_id),updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO zsl.zsl3_authority_state(singleton) VALUES(true) ON CONFLICT(singleton) DO NOTHING;
COMMIT;
