BEGIN;
DROP VIEW IF EXISTS zsl.certified_canonical_locations;
DROP VIEW IF EXISTS zsl.r1b_location_candidates;
DROP VIEW IF EXISTS zsl.zsl2_current_certification;
DROP FUNCTION IF EXISTS zsl.locations_within_radius(numeric,numeric,numeric,text[]);
DROP FUNCTION IF EXISTS zsl.location_relationship_graph(uuid);
-- Historical canonical data, lineage, conflicts, and certifications are intentionally retained.
UPDATE zsl.zsl2_schema_state SET engine_version='zsl2-v2.1.0-ROLLED_BACK' WHERE singleton;
COMMIT;
