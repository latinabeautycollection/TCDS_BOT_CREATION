-- Execute in STAGING against production-scale data. Replace psql variables with a real governed run/source.
\set ON_ERROR_STOP on
\echo 'ZSL2 V2.1.2 query-plan certification'
EXPLAIN (ANALYZE,BUFFERS,WAL,VERBOSE,SETTINGS)
SELECT cr.record_id,cr.ordinal
FROM zsl.zsl2_source_bindings b
JOIN zsl.certified_release_records cr ON cr.source_key=b.source_key AND cr.release_id=b.release_id AND cr.ingest_run_id=b.ingest_run_id
WHERE b.normalization_run_id=:'run_id'::uuid AND b.source_key=:'source_key'
  AND (cr.ordinal>:'last_ordinal'::bigint OR (cr.ordinal=:'last_ordinal'::bigint AND cr.record_id>:'last_record_id'::uuid))
ORDER BY cr.ordinal,cr.record_id LIMIT 1000;

EXPLAIN (ANALYZE,BUFFERS,WAL,VERBOSE,SETTINGS)
SELECT r.relationship_id
FROM zsl.location_relationships r
WHERE r.parent_location_id=:'parent_id'::uuid AND r.child_location_id=:'child_id'::uuid
  AND r.relationship_type=:'relationship_type' AND r.authority=:'authority' AND r.source_release_id=:'release_id'::uuid;
