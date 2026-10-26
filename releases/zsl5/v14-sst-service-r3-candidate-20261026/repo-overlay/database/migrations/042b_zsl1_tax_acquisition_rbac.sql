-- TCDS 042b: ZSL1 tax acquisition separation of duties / immutability
BEGIN;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl_tax_acq_collector') THEN CREATE ROLE zsl_tax_acq_collector NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl_tax_acq_normalizer') THEN CREATE ROLE zsl_tax_acq_normalizer NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl_tax_acq_certifier') THEN CREATE ROLE zsl_tax_acq_certifier NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl_tax_acq_publisher') THEN CREATE ROLE zsl_tax_acq_publisher NOLOGIN; END IF;
END $$;
REVOKE ALL ON SCHEMA zsl_tax_acq FROM PUBLIC;
GRANT USAGE ON SCHEMA zsl_tax_acq TO zsl_tax_acq_collector,zsl_tax_acq_normalizer,zsl_tax_acq_certifier,zsl_tax_acq_publisher;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON ALL TABLES IN SCHEMA zsl_tax_acq FROM PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA zsl_tax_acq TO zsl_tax_acq_certifier,zsl_tax_acq_publisher;
GRANT SELECT,INSERT ON zsl_tax_acq.conflicts,zsl_tax_acq.applicability_assertions,zsl_tax_acq.family_coverage_attestations TO zsl_tax_acq_normalizer;
GRANT SELECT,INSERT,UPDATE ON zsl_tax_acq.local_authority_coverage,zsl_tax_acq.address_resolution_quality TO zsl_tax_acq_normalizer;
GRANT SELECT ON zsl.source_registry,zsl.source_releases,zsl.ingest_runs,zsl.source_artifacts,zsl.schema_contracts,zsl.schema_validation_runs,zsl.reconciliation_runs,zsl.certification_runs,zsl.release_record_memberships TO zsl_tax_acq_normalizer,zsl_tax_acq_certifier,zsl_tax_acq_publisher;
GRANT SELECT ON zsl_raw.raw_records TO zsl_tax_acq_normalizer,zsl_tax_acq_certifier,zsl_tax_acq_publisher;
CREATE OR REPLACE FUNCTION zsl_tax_acq.reject_immutable_mutation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'ZSL_TAX_ACQ_IMMUTABLE_HISTORY'; END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['canonical_records','release_lineage','national_publication_memberships','national_family_coverage','national_local_coverage','national_resolution_coverage'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS %I ON zsl_tax_acq.%I','trg_'||t||'_immutable',t);
  EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON zsl_tax_acq.%I FOR EACH ROW EXECUTE FUNCTION zsl_tax_acq.reject_immutable_mutation()','trg_'||t||'_immutable',t);
 END LOOP;
END $$;
COMMIT;
