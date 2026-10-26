-- TCDS 046c: explicit 10-category runtime certification
BEGIN;
ALTER TABLE zsl_tax_acq.runtime_test_cases DROP CONSTRAINT IF EXISTS runtime_test_cases_test_class_check;
ALTER TABLE zsl_tax_acq.runtime_test_cases ADD CONSTRAINT runtime_test_cases_test_class_check CHECK(test_class IN('GOLDEN','CATEGORY','ADVERSARIAL','REPLAY','ROLLBACK'));
ALTER TABLE zsl_tax_acq.runtime_test_results DROP CONSTRAINT IF EXISTS runtime_test_results_test_class_check;
ALTER TABLE zsl_tax_acq.runtime_test_results ADD CONSTRAINT runtime_test_results_test_class_check CHECK(test_class IN('GOLDEN','CATEGORY','ADVERSARIAL','REPLAY','ROLLBACK'));

CREATE OR REPLACE VIEW zsl_tax_acq.v_runtime_certification_readiness AS
SELECT b.build_run_id,
 (SELECT count(distinct state_code) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='PASS') AS golden_states_passed,
 (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='FAIL') AS golden_failures,
 (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='NOT_EXECUTED') AS golden_not_executed,
 (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='ADVERSARIAL' AND r.status='FAIL') AS adversarial_failures,
 (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='ADVERSARIAL' AND r.status='NOT_EXECUTED') AS adversarial_not_executed,
 ((SELECT count(distinct state_code) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='PASS')=51
  AND (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='CATEGORY' AND r.status='PASS')=10
  AND (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class IN('GOLDEN','CATEGORY','ADVERSARIAL') AND r.status<>'PASS')=0) AS ready,
 (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='CATEGORY' AND r.status='PASS') AS category_tests_passed,
 (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='CATEGORY' AND r.status<>'PASS') AS category_tests_not_passed

FROM zsl.zsl5_build_runs b WHERE b.engine_version='zsl5-v1.4.0';
COMMIT;
