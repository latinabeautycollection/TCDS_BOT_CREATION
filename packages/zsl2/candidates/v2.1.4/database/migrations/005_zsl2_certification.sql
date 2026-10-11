BEGIN;
CREATE TABLE IF NOT EXISTS zsl.zsl2_certification_runs(
  certification_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  engine_version text NOT NULL CHECK(engine_version='zsl2-v2.1.0'),
  package_sha256 text NOT NULL CHECK(package_sha256 ~ '^[0-9a-f]{64}$'),
  git_sha text,
  policy_sha256 text NOT NULL CHECK(policy_sha256 ~ '^[0-9a-f]{64}$'),
  upstream_binding_sha256 text NOT NULL CHECK(upstream_binding_sha256 ~ '^[0-9a-f]{64}$'),
  status text NOT NULL CHECK(status IN('PENDING','CERTIFIED','FAILED','REVOKED','SUPERSEDED')),
  evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'),
  evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION zsl.zsl2_prevent_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'ZSL2_IMMUTABLE_LEDGER:%',TG_TABLE_NAME; END $$;
DROP TRIGGER IF EXISTS trg_zsl2_cert_immutable ON zsl.zsl2_certification_runs;
CREATE TRIGGER trg_zsl2_cert_immutable BEFORE UPDATE OR DELETE ON zsl.zsl2_certification_runs FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_prevent_mutation();
DROP TRIGGER IF EXISTS trg_zsl2_lineage_immutable ON zsl.zsl2_record_lineage;
CREATE TRIGGER trg_zsl2_lineage_immutable BEFORE UPDATE OR DELETE ON zsl.zsl2_record_lineage FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_prevent_mutation();

CREATE OR REPLACE FUNCTION zsl.zsl2_certification_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE st text; fatal_count bigint; lineage_pct numeric; point_pct numeric; binding_count bigint;
BEGIN
 IF NEW.status='CERTIFIED' THEN
   SELECT state INTO st FROM zsl.zsl2_normalization_runs WHERE normalization_run_id=NEW.normalization_run_id;
   IF st<>'RECONCILED' THEN RAISE EXCEPTION 'ZSL2_CERT_REQUIRES_RECONCILED'; END IF;
   SELECT count(*) INTO fatal_count FROM zsl.zsl2_conflicts WHERE normalization_run_id=NEW.normalization_run_id AND severity='FATAL' AND NOT resolved;
   IF fatal_count<>0 THEN RAISE EXCEPTION 'ZSL2_CERT_FATAL_CONFLICTS:%',fatal_count; END IF;
   SELECT count(*) INTO binding_count FROM zsl.zsl2_source_bindings WHERE normalization_run_id=NEW.normalization_run_id;
   IF binding_count<6 THEN RAISE EXCEPTION 'ZSL2_CERT_MISSING_SOURCE_BINDINGS:%',binding_count; END IF;
   IF COALESCE((NEW.evidence->'checks'->>'deterministic_replay')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'ZSL2_CERT_REPLAY_REQUIRED'; END IF;
   IF COALESCE((NEW.evidence->'checks'->>'zero_orphans')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'ZSL2_CERT_ORPHAN_CHECK_REQUIRED'; END IF;
   IF COALESCE((NEW.evidence->'checks'->>'identity_hash_coverage_100')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'ZSL2_CERT_IDENTITY_HASH_REQUIRED'; END IF;
   IF COALESCE((NEW.evidence->'checks'->>'lineage_coverage_100')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'ZSL2_CERT_LINEAGE_REQUIRED'; END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_zsl2_cert_guard ON zsl.zsl2_certification_runs;
CREATE TRIGGER trg_zsl2_cert_guard BEFORE INSERT ON zsl.zsl2_certification_runs FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_certification_guard();

CREATE OR REPLACE VIEW zsl.zsl2_current_certification AS
SELECT DISTINCT ON (normalization_run_id) * FROM zsl.zsl2_certification_runs ORDER BY normalization_run_id,created_at DESC;

CREATE OR REPLACE VIEW zsl.certified_canonical_locations AS
SELECT l.* FROM zsl.locations l
WHERE EXISTS(SELECT 1 FROM zsl.zsl2_current_certification c WHERE c.status='CERTIFIED')
  AND l.active;

REVOKE ALL ON zsl.locations,zsl.location_identifiers,zsl.location_points,zsl.location_geometries,zsl.location_relationships FROM PUBLIC;
REVOKE ALL ON zsl.zsl2_normalization_runs,zsl.zsl2_source_bindings,zsl.zsl2_record_lineage,zsl.zsl2_conflicts,zsl.zsl2_certification_runs FROM PUBLIC;
COMMIT;
