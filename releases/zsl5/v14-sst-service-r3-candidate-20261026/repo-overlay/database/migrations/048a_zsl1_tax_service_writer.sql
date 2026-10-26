-- Observation storage capability only. No state transitions or certification.
BEGIN;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl_tax_ingest_writer') THEN
  CREATE ROLE zsl_tax_ingest_writer NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
 END IF;
END $$;
GRANT USAGE ON SCHEMA zsl,zsl_raw,zsl_tax_acq,extensions TO zsl_tax_ingest_writer;
GRANT SELECT ON zsl.source_registry,zsl.source_releases,zsl.ingest_runs,zsl.source_artifacts,
 zsl_raw.raw_records,zsl.release_record_memberships,zsl_tax_acq.canonical_records,zsl_tax_acq.family_registry
 TO zsl_tax_ingest_writer;
-- These column privileges permit row locks; the function never updates them.
GRANT UPDATE(source_id) ON zsl.source_registry TO zsl_tax_ingest_writer;
GRANT UPDATE(release_id) ON zsl.source_releases TO zsl_tax_ingest_writer;
GRANT UPDATE(ingest_run_id) ON zsl.ingest_runs TO zsl_tax_ingest_writer;
GRANT UPDATE(artifact_id) ON zsl.source_artifacts TO zsl_tax_ingest_writer;
GRANT INSERT ON zsl_raw.raw_records,zsl.release_record_memberships,zsl_tax_acq.canonical_records TO zsl_tax_ingest_writer;

CREATE OR REPLACE FUNCTION zsl_tax_acq.ingest_canonical_record_v2(p_header jsonb,p_row jsonb,p_ordinal bigint,p_json text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,zsl_tax_acq,extensions,pg_temp AS $$
DECLARE binding record;doc jsonb;h text;raw record;m record;cr record;v_raw uuid;v_id uuid;
 rid uuid;iid uuid;aid uuid;v_family text;v_state text;v_natural text;
BEGIN
 IF jsonb_typeof(p_header)<>'object' OR jsonb_typeof(p_row)<>'object' OR p_ordinal<1 OR p_json IS NULL THEN
  RAISE EXCEPTION 'INVALID_CANONICAL_RECORD_INPUT';
 END IF;
 rid:=(p_header->>'releaseId')::uuid;iid:=(p_header->>'ingestRunId')::uuid;aid:=(p_header->>'artifactId')::uuid;
 doc:=p_json::jsonb;
 IF jsonb_typeof(doc)<>'object' OR doc IS DISTINCT FROM p_row->'record' THEN RAISE EXCEPTION 'RECORD_DOCUMENT_MISMATCH'; END IF;
 v_family:=p_row->>'family';v_state:=p_row->>'stateCode';v_natural:=p_row->>'naturalKey';
 IF v_family IS NULL OR v_state IS NULL OR v_natural IS NULL OR btrim(v_natural)='' OR v_state!~'^[A-Z]{2}$'
  OR NOT EXISTS(SELECT 1 FROM zsl_tax_acq.family_registry f WHERE f.family=p_row->>'family' AND f.enabled)
  THEN RAISE EXCEPTION 'UNKNOWN_OR_INVALID_TAX_RECORD'; END IF;
 IF doc->>'record_type' IS DISTINCT FROM v_family OR doc->>'state_code' IS DISTINCT FROM v_state
  OR doc->>'natural_key' IS DISTINCT FROM v_natural OR doc->>'source_key' IS DISTINCT FROM p_header->>'sourceKey'
  OR doc->>'source_release_id' IS DISTINCT FROM rid::text
  OR doc->>'parser_version' IS DISTINCT FROM p_row->>'parserVersion'
  OR doc->>'normalization_version' IS DISTINCT FROM p_row->>'normalizationVersion'
  OR doc->>'authority_rank' IS DISTINCT FROM p_row->>'authorityRank'
  OR coalesce(p_row->>'parserVersion','') IN ('','PENDING_PARSE')
  OR coalesce(p_row->>'normalizationVersion','')=''
  THEN RAISE EXCEPTION 'RECORD_ENVELOPE_MISMATCH'; END IF;
 SELECT s.source_key,s.enabled,sr.release_key,sr.status release_status,i.state,a.sha256
 INTO binding FROM zsl.source_releases sr JOIN zsl.source_registry s ON s.source_id=sr.source_id
 JOIN zsl.ingest_runs i ON i.release_id=sr.release_id
 JOIN zsl.source_artifacts a ON a.release_id=sr.release_id AND a.retrieval_ingest_run_id=i.ingest_run_id
 WHERE sr.release_id=rid AND i.ingest_run_id=iid AND a.artifact_id=aid FOR UPDATE OF s,sr,i,a;
 IF NOT FOUND OR binding.source_key IS DISTINCT FROM p_header->>'sourceKey'
  OR binding.release_key IS DISTINCT FROM p_header->>'releaseKey' OR binding.enabled IS DISTINCT FROM true
  THEN RAISE EXCEPTION 'INGEST_SOURCE_RELEASE_ARTIFACT_BINDING_MISMATCH'; END IF;
 IF binding.state NOT IN ('DISCOVERED','DOWNLOADED','VALIDATED','LOADED')
  OR binding.release_status NOT IN ('DISCOVERED','DOWNLOADED','VALIDATED','LOADED')
  THEN RAISE EXCEPTION 'INGEST_OR_RELEASE_NOT_WRITABLE'; END IF;
 IF doc->>'source_artifact_sha256' IS DISTINCT FROM binding.sha256 THEN RAISE EXCEPTION 'SOURCE_ARTIFACT_SHA_BINDING_MISMATCH'; END IF;
 h:=encode(extensions.digest(convert_to(p_json,'UTF8'),'sha256'),'hex');
 IF p_row ? 'recordSha256' AND p_row->>'recordSha256' IS DISTINCT FROM h THEN RAISE EXCEPTION 'RECORD_SHA_MISMATCH'; END IF;
 INSERT INTO zsl_raw.raw_records(record_id,record_sha256,natural_key,record) VALUES(gen_random_uuid(),h,v_natural,doc)
 ON CONFLICT(record_sha256) DO NOTHING;
 SELECT r.record_id,r.natural_key,r.record INTO raw FROM zsl_raw.raw_records r WHERE r.record_sha256=h;
 IF raw.natural_key IS DISTINCT FROM v_natural OR raw.record IS DISTINCT FROM doc THEN RAISE EXCEPTION 'RAW_RECORD_IMMUTABILITY_CONFLICT'; END IF;
 v_raw:=raw.record_id;
 INSERT INTO zsl.release_record_memberships(release_id,artifact_id,record_id,ordinal,ingest_run_id,natural_key)
 VALUES(rid,aid,v_raw,p_ordinal,iid,v_natural) ON CONFLICT(release_id,artifact_id,ordinal) DO NOTHING;
 SELECT mm.* INTO m FROM zsl.release_record_memberships mm WHERE mm.release_id=rid AND mm.artifact_id=aid AND mm.ordinal=p_ordinal;
 IF m.record_id IS DISTINCT FROM v_raw OR m.ingest_run_id IS DISTINCT FROM iid OR m.natural_key IS DISTINCT FROM v_natural
  THEN RAISE EXCEPTION 'RELEASE_MEMBERSHIP_IMMUTABILITY_CONFLICT'; END IF;
 INSERT INTO zsl_tax_acq.canonical_records(canonical_record_id,ingest_run_id,release_id,artifact_id,raw_record_id,record_type,state_code,natural_key,authority_rank,
  published_at,effective_from,effective_to,legal_citation,record_document,record_sha256,parser_version,normalization_version)
 VALUES(gen_random_uuid(),iid,rid,aid,v_raw,v_family,v_state,v_natural,(p_row->>'authorityRank')::integer,
  (doc->>'published_at')::timestamptz,(doc->>'effective_from')::timestamptz,(doc->>'effective_to')::timestamptz,
  doc->>'legal_citation',doc,h,p_row->>'parserVersion',p_row->>'normalizationVersion')
 ON CONFLICT(ingest_run_id,record_sha256) DO NOTHING;
 SELECT c.* INTO cr FROM zsl_tax_acq.canonical_records c WHERE c.ingest_run_id=iid AND c.record_sha256=h;
 IF cr.release_id IS DISTINCT FROM rid OR cr.artifact_id IS DISTINCT FROM aid OR cr.raw_record_id IS DISTINCT FROM v_raw
  OR cr.record_type IS DISTINCT FROM v_family OR btrim(cr.state_code) IS DISTINCT FROM v_state
  OR cr.natural_key IS DISTINCT FROM v_natural OR cr.authority_rank IS DISTINCT FROM (p_row->>'authorityRank')::integer
  OR cr.parser_version IS DISTINCT FROM p_row->>'parserVersion' OR cr.normalization_version IS DISTINCT FROM p_row->>'normalizationVersion'
  OR cr.record_document IS DISTINCT FROM doc THEN RAISE EXCEPTION 'CANONICAL_METADATA_IMMUTABILITY_CONFLICT'; END IF;
 RETURN cr.canonical_record_id;
END $$;
REVOKE ALL ON FUNCTION zsl_tax_acq.ingest_canonical_record_v2(jsonb,jsonb,bigint,text) FROM PUBLIC;
ALTER FUNCTION zsl_tax_acq.ingest_canonical_record_v2(jsonb,jsonb,bigint,text) OWNER TO zsl_tax_ingest_writer;
GRANT EXECUTE ON FUNCTION zsl_tax_acq.ingest_canonical_record_v2(jsonb,jsonb,bigint,text) TO zsl_tax_acq_normalizer;
COMMIT;
