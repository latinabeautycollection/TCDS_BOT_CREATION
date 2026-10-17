BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
CREATE OR REPLACE FUNCTION zsl.zsl3_required_check_codes() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$ SELECT ARRAY[
'exact_zsl1_package','exact_zsl2_package','zsl1_bindings_current','zsl2_authority_current',
'source_policy_sha_match','source_vintage_coherence','acs_metadata_complete','acs_metadata_semantic_match',
'zip_zcta_separation','zbp_postal_resolution','bea_msa_reconciliation_complete','bea_msa_authority_valid',
'naics_vocabulary_valid','naics_crosswalk_valid','raw_fact_lineage_100','derived_feature_lineage_100',
'feature_definition_coverage_100','formula_sha_coverage_100','deterministic_formula_replay_100','percentile_replay_100',
'snapshot_hash_replay_100','freshness_replay_100','confidence_replay_100','missingness_replay_100',
'source_coverage_valid','source_fact_coverage_valid','derived_feature_coverage_valid','location_coverage_valid',
'zero_unresolved_fatal_conflicts','zero_orphan_location_mappings','percentile_sample_protection','suppression_handling',
'no_model_prior_leakage','package_sha_match','git_sha_present','migration_manifest_match','dependency_lock_valid','rbac_verified','rollback_verified'
]::text[] $$;

CREATE OR REPLACE FUNCTION zsl.zsl3_certification_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE missing_count int;failed_count int;not_executed_count int;br zsl.zsl3_build_runs%ROWTYPE; rr zsl.zsl3_runtime_check_runs%ROWTYPE;
BEGIN
 IF NEW.status<>'CERTIFIED' THEN RETURN NEW; END IF;
 SELECT * INTO br FROM zsl.zsl3_build_runs WHERE build_run_id=NEW.build_run_id;
 IF br.state<>'RECONCILED' THEN RAISE EXCEPTION 'ZSL3_BUILD_NOT_RECONCILED'; END IF;
 SELECT * INTO rr FROM zsl.zsl3_runtime_check_runs WHERE runtime_check_run_id=NEW.runtime_check_run_id AND build_run_id=NEW.build_run_id;
 IF rr.runtime_check_run_id IS NULL OR rr.status<>'PASS' THEN RAISE EXCEPTION 'ZSL3_PASSING_RUNTIME_CHECK_RUN_REQUIRED'; END IF;
 IF br.package_sha256<>NEW.package_sha256 OR br.git_sha<>NEW.git_sha OR br.source_policy_sha256<>NEW.source_policy_sha256
 OR br.feature_policy_sha256<>NEW.feature_policy_sha256 OR br.confidence_policy_sha256<>NEW.confidence_policy_sha256
 OR br.freshness_policy_sha256<>NEW.freshness_policy_sha256 OR br.naics_policy_sha256<>NEW.naics_policy_sha256
 OR br.source_manifest_sha256<>NEW.source_manifest_sha256 OR br.migration_manifest_sha256<>NEW.migration_manifest_sha256
 OR br.dependency_tree_sha256<>NEW.dependency_tree_sha256 OR br.certification_policy_sha256<>NEW.certification_policy_sha256 OR br.feature_registry_sha256<>NEW.feature_registry_sha256 THEN RAISE EXCEPTION 'ZSL3_CERTIFICATION_BINDING_MISMATCH'; END IF;
 IF NOT zsl.zsl3_bindings_still_valid(NEW.build_run_id) THEN RAISE EXCEPTION 'ZSL3_UPSTREAM_BINDINGS_INVALID'; END IF;
 SELECT count(*) INTO missing_count FROM unnest(zsl.zsl3_required_check_codes()) c
 WHERE NOT EXISTS(SELECT 1 FROM zsl.zsl3_runtime_checks rc WHERE rc.runtime_check_run_id=NEW.runtime_check_run_id AND rc.check_code=c);
 SELECT count(*) INTO failed_count FROM zsl.zsl3_runtime_checks rc WHERE rc.runtime_check_run_id=NEW.runtime_check_run_id AND rc.status='FAIL';
 SELECT count(*) INTO not_executed_count FROM zsl.zsl3_runtime_checks rc WHERE rc.runtime_check_run_id=NEW.runtime_check_run_id AND rc.status='NOT_EXECUTED';
 IF missing_count>0 OR failed_count>0 OR not_executed_count>0 THEN
   RAISE EXCEPTION 'ZSL3_CERTIFICATION_CHECKS_INCOMPLETE:missing=% failed=% not_executed=%',missing_count,failed_count,not_executed_count;
 END IF;
 NEW.certified_at:=COALESCE(NEW.certified_at,now());RETURN NEW;
END$$;
DROP TRIGGER IF EXISTS trg_zsl3_certification_guard ON zsl.zsl3_certification_runs;
CREATE TRIGGER trg_zsl3_certification_guard BEFORE INSERT ON zsl.zsl3_certification_runs FOR EACH ROW EXECUTE FUNCTION zsl.zsl3_certification_guard();
COMMIT;
