-- TCDS 042c: Real raw-record load and strict ZSL1 certification
BEGIN;
CREATE OR REPLACE FUNCTION zsl_tax_acq.sha256_jsonb(p_doc jsonb) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$ SELECT encode(extensions.digest(convert_to(p_doc::text,'UTF8'),'sha256'),'hex') $$;

CREATE OR REPLACE FUNCTION zsl_tax_acq.load_canonical_record(
 p_ingest_run_id uuid,p_release_id uuid,p_artifact_id uuid,p_ordinal bigint,p_record_type text,p_state_code char(2),p_natural_key text,p_authority_rank integer,
 p_record_document jsonb,p_parser_version text,p_normalization_version text,p_published_at timestamptz DEFAULT NULL,p_effective_from timestamptz DEFAULT NULL,p_effective_to timestamptz DEFAULT NULL,p_legal_citation text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl,zsl_raw,zsl_tax_acq,extensions AS $$
DECLARE v_raw uuid;v_sha text;v_id uuid;v_release uuid;
BEGIN
 IF p_record_type NOT IN (SELECT family FROM zsl_tax_acq.family_registry WHERE enabled) THEN RAISE EXCEPTION 'UNKNOWN_TAX_FAMILY:%',p_record_type; END IF;
 IF p_parser_version IS NULL OR btrim(p_parser_version)='' OR p_parser_version='PENDING_PARSE' THEN RAISE EXCEPTION 'VALID_PARSER_VERSION_REQUIRED'; END IF;
 IF p_ordinal<1 OR jsonb_typeof(p_record_document)<>'object' THEN RAISE EXCEPTION 'INVALID_CANONICAL_RECORD'; END IF;
 SELECT release_id INTO v_release FROM zsl.ingest_runs WHERE ingest_run_id=p_ingest_run_id; IF v_release IS NULL OR v_release<>p_release_id THEN RAISE EXCEPTION 'INGEST_RELEASE_MISMATCH'; END IF;
 IF NOT EXISTS(SELECT 1 FROM zsl.source_artifacts WHERE artifact_id=p_artifact_id AND release_id=p_release_id AND retrieval_ingest_run_id=p_ingest_run_id) THEN RAISE EXCEPTION 'ARTIFACT_INGEST_RELEASE_MISMATCH'; END IF;
 v_sha:=zsl_tax_acq.sha256_jsonb(p_record_document);
 SELECT record_id INTO v_raw FROM zsl_raw.raw_records WHERE record_sha256=v_sha;
 IF v_raw IS NULL THEN INSERT INTO zsl_raw.raw_records(record_id,record_sha256,natural_key,record) VALUES(gen_random_uuid(),v_sha,p_natural_key,p_record_document) RETURNING record_id INTO v_raw; END IF;
 INSERT INTO zsl.release_record_memberships(release_id,artifact_id,record_id,ordinal,ingest_run_id,natural_key) VALUES(p_release_id,p_artifact_id,v_raw,p_ordinal,p_ingest_run_id,p_natural_key) ON CONFLICT(release_id,artifact_id,ordinal) DO UPDATE SET record_id=EXCLUDED.record_id,ingest_run_id=EXCLUDED.ingest_run_id,natural_key=EXCLUDED.natural_key WHERE zsl.release_record_memberships.record_id=EXCLUDED.record_id AND zsl.release_record_memberships.ingest_run_id=EXCLUDED.ingest_run_id AND zsl.release_record_memberships.natural_key=EXCLUDED.natural_key;
 IF NOT FOUND THEN RAISE EXCEPTION 'RELEASE_MEMBERSHIP_ORDINAL_COLLISION'; END IF;
 INSERT INTO zsl_tax_acq.canonical_records(ingest_run_id,release_id,artifact_id,raw_record_id,record_type,state_code,natural_key,authority_rank,published_at,effective_from,effective_to,legal_citation,record_document,record_sha256,parser_version,normalization_version)
 VALUES(p_ingest_run_id,p_release_id,p_artifact_id,v_raw,p_record_type,p_state_code,p_natural_key,p_authority_rank,p_published_at,p_effective_from,p_effective_to,p_legal_citation,p_record_document,v_sha,p_parser_version,p_normalization_version)
 ON CONFLICT(ingest_run_id,record_sha256) DO UPDATE SET raw_record_id=EXCLUDED.raw_record_id RETURNING canonical_record_id INTO v_id;
 RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION zsl_tax_acq.certify_ingest_strict(p_ingest_run_id uuid,p_actor text,p_evidence jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl,zsl_raw,zsl_tax_acq,extensions AS $$
DECLARE r zsl.ingest_runs%ROWTYPE;rel zsl.source_releases%ROWTYPE;v_art integer;v_members bigint;v_canon bigint;v_distinct bigint;v_cert uuid;v_ev jsonb;v_sha text;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('TCDS:ZSL1:TAX:CERT:'||p_ingest_run_id::text,0));
 SELECT * INTO r FROM zsl.ingest_runs WHERE ingest_run_id=p_ingest_run_id FOR UPDATE; IF r.ingest_run_id IS NULL THEN RAISE EXCEPTION 'INGEST_NOT_FOUND'; END IF;
 SELECT * INTO rel FROM zsl.source_releases WHERE release_id=r.release_id FOR UPDATE;
 IF r.state<>'RECONCILED' OR rel.status<>'RECONCILED' THEN RAISE EXCEPTION 'INGEST_AND_RELEASE_MUST_BE_RECONCILED'; END IF;
 IF r.git_sha IS NULL OR r.git_sha='UNSET' OR r.git_sha!~'^[0-9a-f]{7,64}$' THEN RAISE EXCEPTION 'VALID_GIT_SHA_REQUIRED'; END IF;
 IF r.package_sha256 IS NULL OR r.package_sha256=repeat('0',64) THEN RAISE EXCEPTION 'VALID_PACKAGE_SHA_REQUIRED'; END IF;
 IF r.schema_contract_sha256 IS NULL OR r.schema_contract_sha256=repeat('0',64) THEN RAISE EXCEPTION 'VALID_SCHEMA_CONTRACT_SHA_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM zsl.schema_contracts sc JOIN zsl.source_releases sr ON sr.release_id=r.release_id WHERE sc.source_id=sr.source_id AND sc.contract_sha256=r.schema_contract_sha256 AND sc.active=true) THEN RAISE EXCEPTION 'ACTIVE_SOURCE_SCHEMA_CONTRACT_REQUIRED'; END IF;
 IF r.parser_replay_pass IS DISTINCT FROM true OR r.parser_replay_sha256 IS NULL OR r.ordered_record_sha256 IS NULL THEN RAISE EXCEPTION 'PARSER_REPLAY_REQUIRED'; END IF;
 SELECT count(*) INTO v_art FROM zsl.source_artifacts a WHERE a.retrieval_ingest_run_id=p_ingest_run_id; IF v_art=0 THEN RAISE EXCEPTION 'SOURCE_ARTIFACT_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM zsl.source_artifacts a WHERE a.retrieval_ingest_run_id=p_ingest_run_id AND NOT EXISTS(SELECT 1 FROM zsl.schema_validation_runs s WHERE s.ingest_run_id=p_ingest_run_id AND s.artifact_id=a.artifact_id AND s.status='PASS')) THEN RAISE EXCEPTION 'ALL_ARTIFACT_SCHEMA_VALIDATIONS_MUST_PASS'; END IF;
 IF EXISTS(SELECT 1 FROM zsl.source_artifacts a WHERE a.retrieval_ingest_run_id=p_ingest_run_id AND NOT EXISTS(SELECT 1 FROM zsl.reconciliation_runs q WHERE q.ingest_run_id=p_ingest_run_id AND q.artifact_id=a.artifact_id AND q.parser_replay_pass=true)) THEN RAISE EXCEPTION 'ALL_ARTIFACT_RECONCILIATIONS_MUST_PASS'; END IF;
 SELECT count(*),count(DISTINCT record_id) INTO v_members,v_distinct FROM zsl.release_record_memberships WHERE ingest_run_id=p_ingest_run_id;
 SELECT count(*) INTO v_canon FROM zsl_tax_acq.canonical_records WHERE ingest_run_id=p_ingest_run_id;
 IF v_members=0 OR v_canon=0 OR v_members<>r.loaded_membership_count OR v_members<>r.parsed_record_count OR v_distinct<>r.distinct_record_count OR v_canon<>v_distinct THEN RAISE EXCEPTION 'INGEST_COUNT_RECONCILIATION_FAILED'; END IF;
 IF EXISTS(SELECT 1 FROM zsl_tax_acq.canonical_records WHERE ingest_run_id=p_ingest_run_id AND raw_record_id IS NULL) THEN RAISE EXCEPTION 'RAW_RECORD_LINEAGE_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM zsl_tax_acq.conflicts WHERE ingest_run_id=p_ingest_run_id AND severity='FATAL' AND resolved=false) THEN RAISE EXCEPTION 'UNRESOLVED_FATAL_CONFLICT'; END IF;
 IF EXISTS(SELECT 1 FROM zsl.certification_runs WHERE ingest_run_id=p_ingest_run_id AND status='CERTIFIED') THEN RAISE EXCEPTION 'INGEST_ALREADY_CERTIFIED'; END IF;
 v_cert:=gen_random_uuid(); v_ev:=jsonb_build_object('ingestRunId',p_ingest_run_id,'releaseId',r.release_id,'parsed',v_canon,'memberships',v_members,'distinct',v_distinct,'parserReplaySha256',r.parser_replay_sha256,'orderedRecordSha256',r.ordered_record_sha256,'packageSha256',r.package_sha256,'gitSha',r.git_sha,'actor',p_actor,'evidence',p_evidence);
 v_sha:=zsl_tax_acq.sha256_jsonb(v_ev); INSERT INTO zsl.certification_runs(certification_run_id,ingest_run_id,status,evidence,evidence_sha256,certifier_actor,certified_at) VALUES(v_cert,p_ingest_run_id,'CERTIFIED',v_ev,v_sha,p_actor,now());
 RETURN v_cert;
END $$;
REVOKE ALL ON FUNCTION zsl_tax_acq.load_canonical_record(uuid,uuid,uuid,bigint,text,character,text,integer,jsonb,text,text,timestamptz,timestamptz,timestamptz,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION zsl_tax_acq.certify_ingest_strict(uuid,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION zsl_tax_acq.load_canonical_record(uuid,uuid,uuid,bigint,text,character,text,integer,jsonb,text,text,timestamptz,timestamptz,timestamptz,text) TO zsl_tax_acq_normalizer;
GRANT EXECUTE ON FUNCTION zsl_tax_acq.certify_ingest_strict(uuid,text,jsonb) TO zsl_tax_acq_certifier;
COMMIT;
