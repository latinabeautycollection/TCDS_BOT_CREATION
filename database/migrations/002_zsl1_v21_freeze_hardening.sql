BEGIN;
ALTER TABLE zsl.source_artifacts DROP CONSTRAINT IF EXISTS source_artifacts_release_id_sha256_key;
ALTER TABLE zsl.source_artifacts ADD COLUMN IF NOT EXISTS artifact_role text NOT NULL DEFAULT 'PRIMARY' CHECK(artifact_role IN ('PRIMARY','METADATA','DICTIONARY'));
CREATE UNIQUE INDEX IF NOT EXISTS uq_source_artifact_run_sha ON zsl.source_artifacts(retrieval_ingest_run_id,sha256,artifact_role);

ALTER TABLE zsl.release_record_memberships ADD COLUMN IF NOT EXISTS ingest_run_id uuid REFERENCES zsl.ingest_runs(ingest_run_id);
ALTER TABLE zsl.release_record_memberships ADD COLUMN IF NOT EXISTS natural_key text;
UPDATE zsl.release_record_memberships m SET ingest_run_id=a.retrieval_ingest_run_id,natural_key=r.natural_key
FROM zsl.source_artifacts a,zsl_raw.raw_records r WHERE m.artifact_id=a.artifact_id AND m.record_id=r.record_id AND (m.ingest_run_id IS NULL OR m.natural_key IS NULL);
ALTER TABLE zsl.release_record_memberships ALTER COLUMN ingest_run_id SET NOT NULL;
ALTER TABLE zsl.release_record_memberships ALTER COLUMN natural_key SET NOT NULL;
CREATE INDEX IF NOT EXISTS ix_membership_run ON zsl.release_record_memberships(ingest_run_id,ordinal);

ALTER TABLE zsl.ingest_runs ADD COLUMN IF NOT EXISTS schema_contract_sha256 text CHECK(schema_contract_sha256 IS NULL OR schema_contract_sha256 ~ '^[0-9a-f]{64}$');
ALTER TABLE zsl.ingest_runs ADD COLUMN IF NOT EXISTS ordered_record_sha256 text CHECK(ordered_record_sha256 IS NULL OR ordered_record_sha256 ~ '^[0-9a-f]{64}$');
ALTER TABLE zsl.ingest_runs ADD COLUMN IF NOT EXISTS parser_replay_sha256 text CHECK(parser_replay_sha256 IS NULL OR parser_replay_sha256 ~ '^[0-9a-f]{64}$');
ALTER TABLE zsl.ingest_runs ADD COLUMN IF NOT EXISTS parser_replay_pass boolean;
ALTER TABLE zsl.ingest_runs ADD COLUMN IF NOT EXISTS adapter_config jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(adapter_config)='object');

CREATE TABLE IF NOT EXISTS zsl.reconciliation_runs(
 reconciliation_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),ingest_run_id uuid NOT NULL REFERENCES zsl.ingest_runs(ingest_run_id),artifact_id uuid NOT NULL REFERENCES zsl.source_artifacts(artifact_id),
 parsed_count bigint NOT NULL CHECK(parsed_count>0),membership_count bigint NOT NULL CHECK(membership_count>0),distinct_record_count bigint NOT NULL CHECK(distinct_record_count>0),
 ordered_record_sha256 text NOT NULL CHECK(ordered_record_sha256 ~ '^[0-9a-f]{64}$'),parser_replay_sha256 text NOT NULL CHECK(parser_replay_sha256 ~ '^[0-9a-f]{64}$'),
 parser_replay_pass boolean NOT NULL,reconciliation_document jsonb NOT NULL CHECK(jsonb_typeof(reconciliation_document)='object'),reconciliation_sha256 text NOT NULL CHECK(reconciliation_sha256 ~ '^[0-9a-f]{64}$'),created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(ingest_run_id,artifact_id));

ALTER TABLE zsl.ingest_audit_events ADD COLUMN IF NOT EXISTS ingest_run_id uuid REFERENCES zsl.ingest_runs(ingest_run_id);
CREATE INDEX IF NOT EXISTS ix_audit_ingest_run ON zsl.ingest_audit_events(ingest_run_id,audit_event_id);

CREATE OR REPLACE FUNCTION zsl.append_ingest_audit_event(p_run uuid,p_type text,p_actor text,p_data jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=zsl,pg_temp AS $$
DECLARE id bigint;sha text;BEGIN IF NOT EXISTS(SELECT 1 FROM zsl.ingest_runs WHERE ingest_run_id=p_run) THEN RAISE EXCEPTION 'INGEST_RUN_NOT_FOUND';END IF;IF btrim(p_type)='' OR btrim(p_actor)='' OR jsonb_typeof(p_data)<>'object' THEN RAISE EXCEPTION 'INVALID_AUDIT_EVENT';END IF;
sha:=encode(digest(convert_to(jsonb_build_object('ingest_run_id',p_run,'event_type',p_type,'actor',p_actor,'event_data',p_data)::text,'UTF8'),'sha256'),'hex');
INSERT INTO zsl.ingest_audit_events(ingest_run_id,event_type,actor,event_data,event_sha256) VALUES(p_run,p_type,p_actor,p_data,sha) RETURNING audit_event_id INTO id;RETURN id;END $$;

DROP TRIGGER IF EXISTS trg_audit_immutable ON zsl.ingest_audit_events;
CREATE TRIGGER trg_audit_immutable BEFORE UPDATE OR DELETE ON zsl.ingest_audit_events FOR EACH ROW EXECUTE FUNCTION zsl.prevent_mutation();
DROP TRIGGER IF EXISTS trg_schema_validation_immutable ON zsl.schema_validation_runs;
CREATE TRIGGER trg_schema_validation_immutable BEFORE UPDATE OR DELETE ON zsl.schema_validation_runs FOR EACH ROW EXECUTE FUNCTION zsl.prevent_mutation();
DROP TRIGGER IF EXISTS trg_reconciliation_immutable ON zsl.reconciliation_runs;
CREATE TRIGGER trg_reconciliation_immutable BEFORE UPDATE OR DELETE ON zsl.reconciliation_runs FOR EACH ROW EXECUTE FUNCTION zsl.prevent_mutation();
DROP TRIGGER IF EXISTS trg_certification_immutable ON zsl.certification_runs;
CREATE TRIGGER trg_certification_immutable BEFORE UPDATE OR DELETE ON zsl.certification_runs FOR EACH ROW EXECUTE FUNCTION zsl.prevent_mutation();

CREATE OR REPLACE VIEW zsl.certified_release_records AS
WITH current_cert AS (
 SELECT DISTINCT ON (cr.ingest_run_id) cr.* FROM zsl.certification_runs cr ORDER BY cr.ingest_run_id,cr.created_at DESC
), effective_run AS (
 SELECT DISTINCT ON (ir.release_id) ir.* FROM zsl.ingest_runs ir JOIN current_cert cr ON cr.ingest_run_id=ir.ingest_run_id AND cr.status='CERTIFIED'
 WHERE ir.state='RECONCILED' ORDER BY ir.release_id,ir.started_at DESC
)
SELECT s.source_key,sr.release_id,sr.release_key,a.artifact_id,rr.record_id,m.natural_key,rr.record,rr.record_sha256,ir.ingest_run_id,m.ordinal
FROM zsl.source_registry s JOIN zsl.source_releases sr ON sr.source_id=s.source_id JOIN effective_run ir ON ir.release_id=sr.release_id
JOIN zsl.source_artifacts a ON a.retrieval_ingest_run_id=ir.ingest_run_id AND a.artifact_role='PRIMARY'
JOIN zsl.release_record_memberships m ON m.ingest_run_id=ir.ingest_run_id AND m.artifact_id=a.artifact_id
JOIN zsl_raw.raw_records rr ON rr.record_id=m.record_id;

DO $$BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl_ingest_worker') THEN
  GRANT SELECT,INSERT ON zsl.reconciliation_runs TO zsl_ingest_worker;
  GRANT EXECUTE ON FUNCTION zsl.append_ingest_audit_event(uuid,text,text,jsonb) TO zsl_ingest_worker;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl_certifier') THEN GRANT SELECT ON zsl.reconciliation_runs TO zsl_certifier;END IF;
END $$;

CREATE OR REPLACE FUNCTION zsl.certification_insert_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=zsl,pg_temp AS $$
DECLARE run_state text; all_true boolean;BEGIN
 IF NEW.status='CERTIFIED' THEN
  SELECT state INTO run_state FROM zsl.ingest_runs WHERE ingest_run_id=NEW.ingest_run_id;
  IF run_state<>'RECONCILED' THEN RAISE EXCEPTION 'CERTIFICATION_REQUIRES_RECONCILED';END IF;
  SELECT COALESCE(bool_and(value::boolean),false) INTO all_true FROM jsonb_each_text(COALESCE(NEW.evidence->'checks','{}'::jsonb));
  IF NOT all_true THEN RAISE EXCEPTION 'CERTIFICATION_CHECK_FAILED';END IF;
  IF NOT EXISTS(SELECT 1 FROM zsl.schema_validation_runs WHERE ingest_run_id=NEW.ingest_run_id AND status='PASS') THEN RAISE EXCEPTION 'CERTIFICATION_SCHEMA_VALIDATION_MISSING';END IF;
  IF NOT EXISTS(SELECT 1 FROM zsl.reconciliation_runs WHERE ingest_run_id=NEW.ingest_run_id AND parser_replay_pass=true) THEN RAISE EXCEPTION 'CERTIFICATION_REPLAY_MISSING';END IF;
 END IF;RETURN NEW;END $$;
DROP TRIGGER IF EXISTS trg_certification_insert_guard ON zsl.certification_runs;
CREATE TRIGGER trg_certification_insert_guard BEFORE INSERT ON zsl.certification_runs FOR EACH ROW EXECUTE FUNCTION zsl.certification_insert_guard();

DO $$BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl_certifier') THEN GRANT EXECUTE ON FUNCTION zsl.certification_insert_guard() TO zsl_certifier; END IF;
END $$;

ALTER TABLE zsl.release_record_memberships DROP CONSTRAINT IF EXISTS release_record_memberships_release_id_artifact_id_record_id_key;
CREATE UNIQUE INDEX IF NOT EXISTS uq_membership_run_natural_key ON zsl.release_record_memberships(ingest_run_id,artifact_id,natural_key);

CREATE OR REPLACE FUNCTION zsl.prevent_certified_release_mutation() RETURNS trigger LANGUAGE plpgsql SET search_path=zsl,pg_temp AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM zsl.ingest_runs ir JOIN zsl.certification_runs cr ON cr.ingest_run_id=ir.ingest_run_id WHERE ir.release_id=OLD.release_id AND cr.status='CERTIFIED') THEN RAISE EXCEPTION 'CERTIFIED_SOURCE_RELEASE_IMMUTABLE';END IF;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
DROP TRIGGER IF EXISTS trg_certified_release_immutable ON zsl.source_releases;
CREATE TRIGGER trg_certified_release_immutable BEFORE UPDATE OR DELETE ON zsl.source_releases FOR EACH ROW EXECUTE FUNCTION zsl.prevent_certified_release_mutation();

CREATE OR REPLACE FUNCTION zsl.prevent_governance_content_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_TABLE_NAME='source_policies' AND (NEW.source_id,NEW.policy_version,NEW.policy_document,NEW.policy_sha256) IS DISTINCT FROM (OLD.source_id,OLD.policy_version,OLD.policy_document,OLD.policy_sha256) THEN RAISE EXCEPTION 'SOURCE_POLICY_CONTENT_IMMUTABLE';END IF;
 IF TG_TABLE_NAME='schema_contracts' AND (NEW.source_id,NEW.contract_version,NEW.contract_document,NEW.contract_sha256) IS DISTINCT FROM (OLD.source_id,OLD.contract_version,OLD.contract_document,OLD.contract_sha256) THEN RAISE EXCEPTION 'SCHEMA_CONTRACT_CONTENT_IMMUTABLE';END IF;
 IF TG_TABLE_NAME='certification_policies' AND (NEW.policy_version,NEW.policy_document,NEW.policy_sha256) IS DISTINCT FROM (OLD.policy_version,OLD.policy_document,OLD.policy_sha256) THEN RAISE EXCEPTION 'CERTIFICATION_POLICY_CONTENT_IMMUTABLE';END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_source_policy_content_immutable ON zsl.source_policies;CREATE TRIGGER trg_source_policy_content_immutable BEFORE UPDATE ON zsl.source_policies FOR EACH ROW EXECUTE FUNCTION zsl.prevent_governance_content_mutation();
DROP TRIGGER IF EXISTS trg_schema_contract_content_immutable ON zsl.schema_contracts;CREATE TRIGGER trg_schema_contract_content_immutable BEFORE UPDATE ON zsl.schema_contracts FOR EACH ROW EXECUTE FUNCTION zsl.prevent_governance_content_mutation();
DROP TRIGGER IF EXISTS trg_cert_policy_content_immutable ON zsl.certification_policies;CREATE TRIGGER trg_cert_policy_content_immutable BEFORE UPDATE ON zsl.certification_policies FOR EACH ROW EXECUTE FUNCTION zsl.prevent_governance_content_mutation();
COMMIT;
