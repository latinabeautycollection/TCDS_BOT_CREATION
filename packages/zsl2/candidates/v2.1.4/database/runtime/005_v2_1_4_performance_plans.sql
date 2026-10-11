\set ON_ERROR_STOP on
-- Execute in staging after a measured V2.1.4 replay. Captures the actual page-fetch and set-based access plans.
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS)
SELECT cr.source_key,cr.release_id,cr.ingest_run_id,cr.ordinal,cr.record_id,cr.record_sha256
FROM zsl.zsl2_source_bindings b
JOIN zsl.certified_release_records cr
  ON cr.source_key=b.source_key AND cr.release_id=b.release_id AND cr.ingest_run_id=b.ingest_run_id
WHERE b.normalization_run_id=:'run_id'::uuid AND b.source_key=:'source_key'
  AND (cr.ordinal>:'last_ordinal'::bigint OR (cr.ordinal=:'last_ordinal'::bigint AND cr.record_id>:'last_record_id'::uuid))
ORDER BY cr.ordinal,cr.record_id LIMIT :'page_size'::int;

EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS)
SELECT l.location_id,l.canonical_key
FROM zsl.locations l
WHERE l.canonical_key=ANY(:'canonical_keys'::text[]);

EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS)
SELECT relationship_id,evidence_sha256
FROM zsl.location_relationships
WHERE parent_location_id=:'parent_id'::uuid AND child_location_id=:'child_id'::uuid
  AND relationship_type=:'relationship_type' AND authority=:'authority'
  AND source_release_id=:'release_id'::uuid;
