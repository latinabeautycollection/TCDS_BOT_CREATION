BEGIN;
CREATE TABLE IF NOT EXISTS zsl_tax_acq.runtime_test_cases(
 case_id text PRIMARY KEY,
 state_code char(2),
 test_class text NOT NULL CHECK(test_class IN('GOLDEN','ADVERSARIAL','REPLAY','ROLLBACK')),
 status text NOT NULL DEFAULT 'EVIDENCE_REQUIRED' CHECK(status IN('EVIDENCE_REQUIRED','APPROVED','RETIRED')),
 input_document jsonb NOT NULL CHECK(jsonb_typeof(input_document)='object'),
 expected_document jsonb CHECK(expected_document IS NULL OR jsonb_typeof(expected_document)='object'),
 independent_evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(independent_evidence)='object'),
 independent_evidence_sha256 text,
 approved_by text,
 approved_at timestamptz,
 CHECK(status<>'APPROVED' OR (expected_document IS NOT NULL AND independent_evidence_sha256~'^[0-9a-f]{64}$' AND approved_by IS NOT NULL AND approved_at IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS zsl_tax_acq.runtime_test_results(
 test_result_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 build_run_id uuid NOT NULL REFERENCES zsl.zsl5_build_runs(build_run_id) ON DELETE RESTRICT,
 case_id text NOT NULL,
 state_code char(2),
 test_class text NOT NULL CHECK(test_class IN('GOLDEN','ADVERSARIAL','REPLAY','ROLLBACK')),
 status text NOT NULL CHECK(status IN('PASS','FAIL','NOT_EXECUTED')),
 evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'),
 evidence_sha256 text NOT NULL CHECK(evidence_sha256~'^[0-9a-f]{64}$'),
 executed_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(build_run_id,case_id,executed_at)
);
CREATE INDEX IF NOT EXISTS ix_tax_runtime_results_build ON zsl_tax_acq.runtime_test_results(build_run_id,test_class,status,state_code);

CREATE OR REPLACE VIEW zsl_tax_acq.v_runtime_certification_readiness AS
SELECT b.build_run_id,
 (SELECT count(distinct state_code) FROM zsl_tax_acq.runtime_test_results r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='PASS') AS golden_states_passed,
 (SELECT count(*) FROM zsl_tax_acq.runtime_test_results r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='FAIL') AS golden_failures,
 (SELECT count(*) FROM zsl_tax_acq.runtime_test_results r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='NOT_EXECUTED') AS golden_not_executed,
 (SELECT count(*) FROM zsl_tax_acq.runtime_test_results r WHERE r.build_run_id=b.build_run_id AND r.test_class='ADVERSARIAL' AND r.status='FAIL') AS adversarial_failures,
 (SELECT count(*) FROM zsl_tax_acq.runtime_test_results r WHERE r.build_run_id=b.build_run_id AND r.test_class='ADVERSARIAL' AND r.status='NOT_EXECUTED') AS adversarial_not_executed,
 ((SELECT count(distinct state_code) FROM zsl_tax_acq.runtime_test_results r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='PASS')=51
  AND (SELECT count(*) FROM zsl_tax_acq.runtime_test_results r WHERE r.build_run_id=b.build_run_id AND r.test_class IN('GOLDEN','ADVERSARIAL') AND r.status<>'PASS')=0) AS ready
FROM zsl.zsl5_build_runs b WHERE b.engine_version='zsl5-v1.4.0';
COMMIT;
