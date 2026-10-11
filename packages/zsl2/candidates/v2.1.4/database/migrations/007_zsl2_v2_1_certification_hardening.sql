BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;

-- Harden certification to exact run/package/policy/source set/runtime checks.
CREATE OR REPLACE FUNCTION zsl.zsl2_certification_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE
  nr zsl.zsl2_normalization_runs%ROWTYPE;
  bad_bindings bigint;
  check_failures bigint;
  required_names text[] := ARRAY[
    'exact_source_set','bound_records_only','zero_fatal_conflicts','zero_orphans',
    'identity_hash_coverage','lineage_coverage','deterministic_replay','hud_ratio_reconciliation',
    'coordinate_sanity','run_membership_complete','upstream_package_match','source_vintage_coherence','derived_hierarchy_coverage'
  ];
  missing_checks bigint;
BEGIN
 IF NEW.status='CERTIFIED' THEN
   SELECT * INTO nr FROM zsl.zsl2_normalization_runs WHERE normalization_run_id=NEW.normalization_run_id;
   IF nr.normalization_run_id IS NULL OR nr.state<>'RECONCILED' THEN RAISE EXCEPTION 'ZSL2_CERT_REQUIRES_RECONCILED'; END IF;
   IF NEW.package_sha256<>nr.package_sha256 THEN RAISE EXCEPTION 'ZSL2_CERT_PACKAGE_SHA_MISMATCH'; END IF;
   IF NEW.policy_sha256<>nr.policy_sha256 THEN RAISE EXCEPTION 'ZSL2_CERT_POLICY_SHA_MISMATCH'; END IF;
   IF NEW.engine_version<>nr.engine_version THEN RAISE EXCEPTION 'ZSL2_CERT_ENGINE_MISMATCH'; END IF;
   IF NOT zsl.zsl2_bindings_still_valid(NEW.normalization_run_id) THEN RAISE EXCEPTION 'ZSL2_CERT_UPSTREAM_BINDING_INVALID'; END IF;

   SELECT count(*) INTO bad_bindings
   FROM zsl.zsl2_source_bindings b
   LEFT JOIN zsl.source_registry s ON s.source_key=b.source_key
   WHERE b.normalization_run_id=NEW.normalization_run_id AND s.source_id IS NULL;
   IF bad_bindings<>0 THEN RAISE EXCEPTION 'ZSL2_CERT_UNKNOWN_BINDINGS:%',bad_bindings; END IF;

   SELECT count(*) INTO missing_checks FROM unnest(required_names) n
   WHERE NOT EXISTS(SELECT 1 FROM zsl.zsl2_runtime_checks c WHERE c.normalization_run_id=NEW.normalization_run_id AND c.check_name=n);
   IF missing_checks<>0 THEN RAISE EXCEPTION 'ZSL2_CERT_MISSING_RUNTIME_CHECKS:%',missing_checks; END IF;

   SELECT count(*) INTO check_failures FROM zsl.zsl2_runtime_checks c
   WHERE c.normalization_run_id=NEW.normalization_run_id AND NOT c.passed;
   IF check_failures<>0 THEN RAISE EXCEPTION 'ZSL2_CERT_RUNTIME_CHECK_FAILURES:%',check_failures; END IF;
 END IF;
 RETURN NEW;
END $$;

-- Activation may only reference the latest CERTIFIED event for that normalization run and valid upstream bindings.
CREATE OR REPLACE FUNCTION zsl.zsl2_authority_event_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE latest_status text; latest_id uuid;
BEGIN
 IF NEW.event_type='ACTIVATED' THEN
   SELECT status,certification_run_id INTO latest_status,latest_id
   FROM zsl.zsl2_certification_runs
   WHERE normalization_run_id=NEW.normalization_run_id
   ORDER BY created_at DESC,certification_run_id DESC LIMIT 1;
   IF latest_status<>'CERTIFIED' OR latest_id IS DISTINCT FROM NEW.certification_run_id THEN
      RAISE EXCEPTION 'ZSL2_ACTIVATION_REQUIRES_LATEST_CERTIFIED_RUN';
   END IF;
   IF NOT zsl.zsl2_bindings_still_valid(NEW.normalization_run_id) THEN RAISE EXCEPTION 'ZSL2_ACTIVATION_UPSTREAM_INVALID'; END IF;
 ELSIF NEW.event_type='REVOKED' THEN
   IF NOT EXISTS(SELECT 1 FROM zsl.zsl2_current_authority a WHERE a.normalization_run_id=NEW.normalization_run_id AND a.certification_run_id=NEW.certification_run_id) THEN
      RAISE EXCEPTION 'ZSL2_REVOKE_REQUIRES_CURRENT_AUTHORITY';
   END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_zsl2_authority_event_guard ON zsl.zsl2_authority_events;
CREATE TRIGGER trg_zsl2_authority_event_guard BEFORE INSERT ON zsl.zsl2_authority_events FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_authority_event_guard();

REVOKE EXECUTE ON FUNCTION zsl.zsl2_certification_guard() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zsl.zsl2_authority_event_guard() FROM PUBLIC;
COMMIT;
