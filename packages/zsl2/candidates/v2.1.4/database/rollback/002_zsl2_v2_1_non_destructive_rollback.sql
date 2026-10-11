BEGIN;
-- Remove V2.1 authority surfaces only. Preserve all historical evidence and memberships.
DROP VIEW IF EXISTS zsl.r1b_location_candidates;
DROP VIEW IF EXISTS zsl.certified_canonical_relationships;
DROP VIEW IF EXISTS zsl.certified_canonical_locations;
DROP VIEW IF EXISTS zsl.zsl2_current_authority;
DROP TRIGGER IF EXISTS trg_zsl2_authority_event_guard ON zsl.zsl2_authority_events;
-- Intentionally DO NOT mutate zsl2_schema_state to an invalid engine value.
COMMIT;
