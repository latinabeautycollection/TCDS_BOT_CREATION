BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;

-- Forward-only compatibility migration. Historical production 009/010 are authoritative
-- and are intentionally not replaced or re-hashed by this package.
DO $$
BEGIN
  IF to_regclass('zsl.zsl2_normalization_runs') IS NULL THEN RAISE EXCEPTION 'ZSL2_BASE_SCHEMA_MISSING:zsl2_normalization_runs'; END IF;
  IF to_regclass('zsl.zsl2_source_bindings') IS NULL THEN RAISE EXCEPTION 'ZSL2_BASE_SCHEMA_MISSING:zsl2_source_bindings'; END IF;
  IF to_regclass('zsl.zsl2_record_lineage') IS NULL THEN RAISE EXCEPTION 'ZSL2_BASE_SCHEMA_MISSING:zsl2_record_lineage'; END IF;
END $$;

-- Normalize live checkpoint surface without dropping any server-owned history.
CREATE TABLE IF NOT EXISTS zsl.zsl2_normalization_checkpoints(
  checkpoint_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  source_key text NOT NULL,
  release_id uuid NOT NULL,
  ingest_run_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'PENDING',
  last_ordinal bigint,
  last_record_id uuid,
  page_number bigint NOT NULL DEFAULT 0,
  records_processed bigint NOT NULL DEFAULT 0,
  locations_processed bigint NOT NULL DEFAULT 0,
  relationships_processed bigint NOT NULL DEFAULT 0,
  lineage_processed bigint NOT NULL DEFAULT 0,
  started_at timestamptz,
  checkpointed_at timestamptz,
  completed_at timestamptz,
  error_code text,
  error_message text,
  checkpoint_evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  checkpoint_sha256 text,
  UNIQUE(normalization_run_id,source_key)
);
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS release_id uuid;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS ingest_run_id uuid;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'PENDING';
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS last_ordinal bigint;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS last_record_id uuid;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS page_number bigint NOT NULL DEFAULT 0;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS records_processed bigint NOT NULL DEFAULT 0;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS locations_processed bigint NOT NULL DEFAULT 0;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS relationships_processed bigint NOT NULL DEFAULT 0;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS lineage_processed bigint NOT NULL DEFAULT 0;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS started_at timestamptz;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS checkpointed_at timestamptz;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS completed_at timestamptz;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS error_code text;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS error_message text;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS checkpoint_evidence jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE zsl.zsl2_normalization_checkpoints ADD COLUMN IF NOT EXISTS checkpoint_sha256 text;

CREATE TABLE IF NOT EXISTS zsl.zsl2_source_snapshots(
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  source_key text NOT NULL,
  release_id uuid NOT NULL,
  ingest_run_id uuid NOT NULL,
  record_count bigint NOT NULL,
  min_ordinal bigint,
  max_ordinal bigint,
  record_set_sha256 text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(normalization_run_id,source_key)
);

CREATE TABLE IF NOT EXISTS zsl.zsl2_performance_measurements(
  measurement_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalization_run_id uuid REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  source_key text,
  page_number bigint,
  operation text NOT NULL,
  rows_affected bigint,
  duration_ms numeric(18,3) NOT NULL,
  planning_ms numeric(18,3),
  buffers_hit bigint,
  buffers_read bigint,
  temp_bytes bigint,
  wal_bytes bigint,
  statement_timeout_ms bigint,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence_sha256 text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS zsl.zsl2_checkpoint_events(
  checkpoint_event_id bigserial PRIMARY KEY,
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  source_key text NOT NULL,
  page_number bigint NOT NULL,
  event_type text NOT NULL,
  last_ordinal bigint,
  last_record_id uuid,
  records_delta bigint NOT NULL DEFAULT 0,
  locations_delta bigint NOT NULL DEFAULT 0,
  relationships_delta bigint NOT NULL DEFAULT 0,
  lineage_delta bigint NOT NULL DEFAULT 0,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence_sha256 text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);


ALTER TABLE zsl.zsl2_source_snapshots ADD COLUMN IF NOT EXISTS release_id uuid;
ALTER TABLE zsl.zsl2_source_snapshots ADD COLUMN IF NOT EXISTS ingest_run_id uuid;
ALTER TABLE zsl.zsl2_source_snapshots ADD COLUMN IF NOT EXISTS record_count bigint NOT NULL DEFAULT 0;
ALTER TABLE zsl.zsl2_source_snapshots ADD COLUMN IF NOT EXISTS min_ordinal bigint;
ALTER TABLE zsl.zsl2_source_snapshots ADD COLUMN IF NOT EXISTS max_ordinal bigint;
ALTER TABLE zsl.zsl2_source_snapshots ADD COLUMN IF NOT EXISTS record_set_sha256 text;

ALTER TABLE zsl.zsl2_performance_measurements ADD COLUMN IF NOT EXISTS normalization_run_id uuid;
ALTER TABLE zsl.zsl2_performance_measurements ADD COLUMN IF NOT EXISTS source_key text;
ALTER TABLE zsl.zsl2_performance_measurements ADD COLUMN IF NOT EXISTS page_number bigint;
ALTER TABLE zsl.zsl2_performance_measurements ADD COLUMN IF NOT EXISTS operation text;
ALTER TABLE zsl.zsl2_performance_measurements ADD COLUMN IF NOT EXISTS rows_affected bigint;
ALTER TABLE zsl.zsl2_performance_measurements ADD COLUMN IF NOT EXISTS duration_ms numeric(18,3);
ALTER TABLE zsl.zsl2_performance_measurements ADD COLUMN IF NOT EXISTS statement_timeout_ms bigint;
ALTER TABLE zsl.zsl2_performance_measurements ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE zsl.zsl2_performance_measurements ADD COLUMN IF NOT EXISTS evidence_sha256 text;

ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS normalization_run_id uuid;
ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS source_key text;
ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS page_number bigint;
ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS event_type text;
ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS last_ordinal bigint;
ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS last_record_id uuid;
ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS records_delta bigint NOT NULL DEFAULT 0;
ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS locations_delta bigint NOT NULL DEFAULT 0;
ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS relationships_delta bigint NOT NULL DEFAULT 0;
ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS lineage_delta bigint NOT NULL DEFAULT 0;
ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS evidence jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE zsl.zsl2_checkpoint_events ADD COLUMN IF NOT EXISTS evidence_sha256 text;

CREATE INDEX IF NOT EXISTS ix_zsl2_checkpoint_run_status ON zsl.zsl2_normalization_checkpoints(normalization_run_id,status);
CREATE INDEX IF NOT EXISTS ix_zsl2_checkpoint_source_status ON zsl.zsl2_normalization_checkpoints(source_key,status);
CREATE INDEX IF NOT EXISTS ix_zsl2_perf_run_source_page_op ON zsl.zsl2_performance_measurements(normalization_run_id,source_key,page_number,operation);
CREATE INDEX IF NOT EXISTS ix_zsl2_checkpoint_event_run_source_page ON zsl.zsl2_checkpoint_events(normalization_run_id,source_key,page_number);

CREATE OR REPLACE FUNCTION zsl.zsl2_lock_source_page(p_run uuid,p_source text)
RETURNS void LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
  SELECT pg_advisory_xact_lock(hashtextextended('TCDS:ZSL2:PAGE:'||p_run::text||':'||p_source,0));
$$;

CREATE OR REPLACE FUNCTION zsl.zsl2_capture_source_snapshot(p_run uuid,p_source text)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,zsl,extensions AS $$
DECLARE b record; n bigint; lo bigint; hi bigint; h text;
BEGIN
 SELECT * INTO b FROM zsl.zsl2_source_bindings WHERE normalization_run_id=p_run AND source_key=p_source;
 IF b.source_key IS NULL THEN RAISE EXCEPTION 'ZSL2_SOURCE_BINDING_MISSING:%',p_source; END IF;
 SELECT count(*),min(cr.ordinal),max(cr.ordinal),
   encode(digest(convert_to(coalesce(string_agg(cr.record_sha256,'' ORDER BY cr.ordinal,cr.record_id),''),'UTF8'),'sha256'),'hex')
 INTO n,lo,hi,h
 FROM zsl.certified_release_records cr
 WHERE cr.source_key=b.source_key AND cr.release_id=b.release_id AND cr.ingest_run_id=b.ingest_run_id;
 INSERT INTO zsl.zsl2_source_snapshots(normalization_run_id,source_key,release_id,ingest_run_id,record_count,min_ordinal,max_ordinal,record_set_sha256)
 VALUES(p_run,p_source,b.release_id,b.ingest_run_id,n,lo,hi,h)
 ON CONFLICT(normalization_run_id,source_key) DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION zsl.zsl2_source_snapshot_still_valid(p_run uuid,p_source text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl,extensions AS $$
DECLARE s record; n bigint; lo bigint; hi bigint; h text;
BEGIN
 SELECT * INTO s FROM zsl.zsl2_source_snapshots WHERE normalization_run_id=p_run AND source_key=p_source;
 IF s.source_key IS NULL THEN RETURN false; END IF;
 SELECT count(*),min(cr.ordinal),max(cr.ordinal),
   encode(digest(convert_to(coalesce(string_agg(cr.record_sha256,'' ORDER BY cr.ordinal,cr.record_id),''),'UTF8'),'sha256'),'hex')
 INTO n,lo,hi,h
 FROM zsl.certified_release_records cr
 WHERE cr.source_key=s.source_key AND cr.release_id=s.release_id AND cr.ingest_run_id=s.ingest_run_id;
 RETURN n=s.record_count AND lo IS NOT DISTINCT FROM s.min_ordinal AND hi IS NOT DISTINCT FROM s.max_ordinal AND h=s.record_set_sha256;
END $$;

CREATE OR REPLACE FUNCTION zsl.zsl2_checkpoint_truth(p_run uuid,p_source text)
RETURNS TABLE(records_processed bigint,locations_processed bigint,relationships_processed bigint,lineage_processed bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
 SELECT
  (SELECT count(*) FROM zsl.zsl2_record_lineage WHERE normalization_run_id=p_run AND source_key=p_source),
  (SELECT count(*) FROM zsl.zsl2_location_run_memberships WHERE normalization_run_id=p_run AND source_key=p_source),
  (SELECT count(*) FROM zsl.zsl2_relationship_run_memberships WHERE normalization_run_id=p_run AND source_key=p_source),
  (SELECT count(*) FROM zsl.zsl2_record_lineage WHERE normalization_run_id=p_run AND source_key=p_source)
$$;

DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_normalizer') THEN
  GRANT SELECT,INSERT,UPDATE ON zsl.zsl2_normalization_checkpoints TO zsl2_normalizer;
  GRANT SELECT,INSERT ON zsl.zsl2_source_snapshots,zsl.zsl2_performance_measurements,zsl.zsl2_checkpoint_events TO zsl2_normalizer;
  GRANT USAGE,SELECT ON SEQUENCE zsl.zsl2_checkpoint_events_checkpoint_event_id_seq TO zsl2_normalizer;
  GRANT EXECUTE ON FUNCTION zsl.zsl2_lock_source_page(uuid,text),zsl.zsl2_capture_source_snapshot(uuid,text),zsl.zsl2_source_snapshot_still_valid(uuid,text),zsl.zsl2_checkpoint_truth(uuid,text) TO zsl2_normalizer;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_certifier') THEN
  GRANT SELECT ON zsl.zsl2_normalization_checkpoints,zsl.zsl2_source_snapshots,zsl.zsl2_performance_measurements,zsl.zsl2_checkpoint_events TO zsl2_certifier;
 END IF;
END $$;
REVOKE EXECUTE ON FUNCTION zsl.zsl2_lock_source_page(uuid,text),zsl.zsl2_capture_source_snapshot(uuid,text),zsl.zsl2_source_snapshot_still_valid(uuid,text),zsl.zsl2_checkpoint_truth(uuid,text) FROM PUBLIC;

COMMIT;
