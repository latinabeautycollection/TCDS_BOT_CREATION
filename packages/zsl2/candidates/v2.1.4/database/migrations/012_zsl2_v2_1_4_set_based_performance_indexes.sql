BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;

-- Access paths for the set-based normalizer. All indexes are forward-only and idempotent.
CREATE INDEX IF NOT EXISTS ix_zsl2_binding_run_source ON zsl.zsl2_source_bindings(normalization_run_id,source_key,release_id,ingest_run_id);
CREATE INDEX IF NOT EXISTS ix_zsl2_lineage_run_source_record ON zsl.zsl2_record_lineage(normalization_run_id,source_key,raw_record_id);
CREATE INDEX IF NOT EXISTS ix_zsl2_lineage_run_source_sha ON zsl.zsl2_record_lineage(normalization_run_id,source_key,raw_record_sha256);
CREATE INDEX IF NOT EXISTS ix_zsl2_loc_member_run_source_sha ON zsl.zsl2_location_run_memberships(normalization_run_id,source_key,source_record_sha256);
CREATE INDEX IF NOT EXISTS ix_zsl2_rel_member_run_source_sha ON zsl.zsl2_relationship_run_memberships(normalization_run_id,source_key,source_record_sha256);
CREATE INDEX IF NOT EXISTS ix_zsl2_relationship_lookup ON zsl.location_relationships(parent_location_id,child_location_id,relationship_type,authority,source_release_id);
CREATE INDEX IF NOT EXISTS ix_zsl2_locations_key_identity ON zsl.locations(canonical_key,identity_sha256);
CREATE INDEX IF NOT EXISTS ix_zsl2_revisions_run_source_sha ON zsl.zsl2_location_revisions(normalization_run_id,source_key,source_record_sha256);

-- certified_release_records is a view in ZSL1 V2.1; index its base membership/run access paths instead of indexing the view.
CREATE INDEX IF NOT EXISTS ix_zsl_ingest_runs_release_state_time ON zsl.ingest_runs(release_id,state,started_at DESC,ingest_run_id);
CREATE INDEX IF NOT EXISTS ix_zsl_membership_ingest_artifact_ordinal_record ON zsl.release_record_memberships(ingest_run_id,artifact_id,ordinal,record_id);
CREATE INDEX IF NOT EXISTS ix_zsl_certification_ingest_created ON zsl.certification_runs(ingest_run_id,created_at DESC,status);

COMMIT;
