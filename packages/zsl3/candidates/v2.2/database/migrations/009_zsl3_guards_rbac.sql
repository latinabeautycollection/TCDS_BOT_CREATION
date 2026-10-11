BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
CREATE OR REPLACE FUNCTION zsl.zsl3_prevent_mutation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'ZSL3_IMMUTABLE_OBJECT'; END $$;
DO $$DECLARE t text;BEGIN
 FOREACH t IN ARRAY ARRAY[
 'zsl3_source_bindings','zsl3_acs_variable_metadata','zsl3_acs_variable_sets','zsl3_acs_geography_profiles',
 'zsl3_naics_vocabularies','zsl3_naics_codes','zsl3_naics_crosswalks','zsl3_naics_feature_groups','zsl3_naics_feature_group_members',
 'zsl3_source_facts','zsl3_fact_lineage','zsl3_regional_price_parity_facts','zsl3_business_activity_facts',
 'zsl3_bea_msa_reconciliation','zsl3_conflicts','zsl3_feature_definitions','zsl3_derived_features','zsl3_feature_lineage',
 'zsl3_geographic_feature_snapshots','zsl3_geographic_feature_snapshot_values','zsl3_runtime_check_runs','zsl3_runtime_checks',
 'zsl3_qa_evidence','zsl3_certification_runs','zsl3_authority_events'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS %I ON zsl.%I','trg_'||t||'_immutable',t);
  EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON zsl.%I FOR EACH ROW EXECUTE FUNCTION zsl.zsl3_prevent_mutation()','trg_'||t||'_immutable',t);
 END LOOP;
END$$;
DO $$BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl3_reader') THEN CREATE ROLE zsl3_reader NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl3_builder') THEN CREATE ROLE zsl3_builder NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl3_certifier') THEN CREATE ROLE zsl3_certifier NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl3_admin') THEN CREATE ROLE zsl3_admin NOLOGIN; END IF;
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'Role creation skipped; apply grants with privileged migration role.';END$$;
DO $$DECLARE r record;BEGIN
 FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='zsl' AND tablename LIKE 'zsl3_%' LOOP
   EXECUTE format('REVOKE ALL ON TABLE zsl.%I FROM PUBLIC',r.tablename);
   IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN EXECUTE format('REVOKE ALL ON TABLE zsl.%I FROM anon',r.tablename); END IF;
   IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN EXECUTE format('REVOKE ALL ON TABLE zsl.%I FROM authenticated',r.tablename); END IF;
 END LOOP;
 REVOKE ALL ON zsl.current_geographic_economic_features FROM PUBLIC;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN REVOKE ALL ON zsl.current_geographic_economic_features FROM anon; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN REVOKE ALL ON zsl.current_geographic_economic_features FROM authenticated; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl3_reader') THEN GRANT USAGE ON SCHEMA zsl TO zsl3_reader; GRANT SELECT ON zsl.current_geographic_economic_features TO zsl3_reader; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl3_builder') THEN
   GRANT USAGE ON SCHEMA zsl TO zsl3_builder;
   GRANT SELECT,INSERT ON zsl.zsl3_build_runs,zsl.zsl3_source_bindings,zsl.zsl3_source_facts,zsl.zsl3_fact_lineage,zsl.zsl3_feature_definitions,zsl.zsl3_derived_features,zsl.zsl3_feature_lineage,zsl.zsl3_geographic_feature_snapshots,zsl.zsl3_geographic_feature_snapshot_values,zsl.zsl3_acs_variable_metadata,zsl.zsl3_acs_variable_sets,zsl.zsl3_acs_geography_profiles,zsl.zsl3_naics_vocabularies,zsl.zsl3_naics_codes,zsl.zsl3_naics_crosswalks,zsl.zsl3_naics_feature_groups,zsl.zsl3_naics_feature_group_members,zsl.zsl3_bea_msa_reconciliation,zsl.zsl3_conflicts TO zsl3_builder;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl3_certifier') THEN
   GRANT USAGE ON SCHEMA zsl TO zsl3_certifier;
   GRANT SELECT ON zsl.zsl3_build_runs,zsl.zsl3_source_bindings,zsl.zsl3_source_facts,zsl.zsl3_fact_lineage,zsl.zsl3_feature_definitions,zsl.zsl3_derived_features,zsl.zsl3_feature_lineage,zsl.zsl3_geographic_feature_snapshots,zsl.zsl3_geographic_feature_snapshot_values,zsl.zsl3_bea_msa_reconciliation,zsl.zsl3_conflicts,zsl.zsl3_runtime_check_runs,zsl.zsl3_runtime_checks,zsl.zsl3_qa_evidence,zsl.certification_runs,zsl.ingest_runs,zsl.source_releases,zsl.source_registry,zsl.schema_validation_runs,zsl.release_record_memberships,zsl.certified_canonical_locations,zsl.zsl2_current_authority TO zsl3_certifier;
   GRANT INSERT ON zsl.zsl3_runtime_check_runs,zsl.zsl3_runtime_checks,zsl.zsl3_qa_evidence,zsl.zsl3_certification_runs,zsl.zsl3_authority_events TO zsl3_certifier;
 END IF;
END$$;
COMMIT;
