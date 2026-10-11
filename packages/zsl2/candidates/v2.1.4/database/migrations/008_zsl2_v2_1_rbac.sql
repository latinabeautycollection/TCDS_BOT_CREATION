BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
DO $$BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_reader') THEN CREATE ROLE zsl2_reader NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_normalizer') THEN CREATE ROLE zsl2_normalizer NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_certifier') THEN CREATE ROLE zsl2_certifier NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_r1b_bridge') THEN CREATE ROLE zsl2_r1b_bridge NOLOGIN; END IF;
END $$;

REVOKE ALL ON zsl.zsl2_normalization_runs,zsl.zsl2_source_bindings,zsl.zsl2_record_lineage,zsl.zsl2_conflicts,zsl.zsl2_certification_runs,
 zsl.zsl2_location_run_memberships,zsl.zsl2_relationship_run_memberships,zsl.zsl2_location_revisions,zsl.zsl2_runtime_checks,zsl.zsl2_authority_events,zsl.zsl2_postal_outside_cbsa_facts,zsl.r1b_location_sync_proposals FROM PUBLIC;

GRANT USAGE ON SCHEMA zsl TO zsl2_reader,zsl2_normalizer,zsl2_certifier,zsl2_r1b_bridge;
GRANT SELECT ON zsl.certified_canonical_locations,zsl.certified_canonical_relationships TO zsl2_reader,zsl2_r1b_bridge;
GRANT SELECT ON zsl.r1b_location_candidates TO zsl2_r1b_bridge;
GRANT SELECT,INSERT,UPDATE ON zsl.zsl2_normalization_runs TO zsl2_normalizer;
GRANT SELECT,INSERT ON zsl.zsl2_source_bindings,zsl.zsl2_record_lineage,zsl.zsl2_conflicts,zsl.zsl2_location_run_memberships,zsl.zsl2_relationship_run_memberships,zsl.zsl2_location_revisions,zsl.zsl2_postal_outside_cbsa_facts TO zsl2_normalizer;
GRANT SELECT ON zsl.zsl2_normalization_runs,zsl.zsl2_source_bindings,zsl.zsl2_record_lineage,zsl.zsl2_conflicts,zsl.zsl2_location_run_memberships,zsl.zsl2_relationship_run_memberships,zsl.zsl2_location_revisions,zsl.zsl2_postal_outside_cbsa_facts TO zsl2_certifier;
GRANT SELECT,INSERT ON zsl.zsl2_runtime_checks,zsl.zsl2_certification_runs,zsl.zsl2_authority_events TO zsl2_certifier;
GRANT SELECT,INSERT ON zsl.r1b_location_sync_proposals TO zsl2_r1b_bridge;

REVOKE EXECUTE ON FUNCTION zsl.locations_within_radius(numeric,numeric,numeric,text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zsl.location_relationship_graph(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION zsl.locations_within_radius(numeric,numeric,numeric,text[]) TO zsl2_reader,zsl2_r1b_bridge;
GRANT EXECUTE ON FUNCTION zsl.location_relationship_graph(uuid) TO zsl2_reader,zsl2_r1b_bridge;

DO $$BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN
   REVOKE ALL ON zsl.zsl2_normalization_runs,zsl.zsl2_source_bindings,zsl.zsl2_record_lineage,zsl.zsl2_conflicts,zsl.zsl2_certification_runs,zsl.zsl2_authority_events,zsl.r1b_location_sync_proposals FROM anon;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN
   REVOKE ALL ON zsl.zsl2_normalization_runs,zsl.zsl2_source_bindings,zsl.zsl2_record_lineage,zsl.zsl2_conflicts,zsl.zsl2_certification_runs,zsl.zsl2_authority_events,zsl.r1b_location_sync_proposals FROM authenticated;
 END IF;
END $$;
COMMIT;
