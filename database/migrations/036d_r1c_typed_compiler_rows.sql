BEGIN;

CREATE OR REPLACE FUNCTION retail.r1c_compile_route(
  p_route_id uuid,
  p_profile_id uuid,
  p_compiler_version_id uuid,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  r record;
  p record;
  c retail.search_compiler_versions%ROWTYPE;
  v_scraper jsonb;
  v_normalized jsonb;
  v_payload jsonb;
  v_evidence jsonb;
  v_key text;
  v_id uuid;
BEGIN
  PERFORM set_config('app.actor_type','service_account',true);
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  IF retail.r1c_r1b_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1C compile blocked: exact R1B V4 binding not current';
  END IF;

  SELECT * INTO r
  FROM retail.effective_search_routes
  WHERE route_id=p_route_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1C compile blocked: route not effective';
  END IF;

  IF retail.r1b_adapter_execution_ready(r.adapter_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'R1C compile blocked: scraper authority not execution-ready';
  END IF;

  SELECT * INTO p
  FROM retail.search_route_compile_profiles
  WHERE id=p_profile_id
    AND route_id=p_route_id
    AND profile_status='active';

  IF NOT FOUND OR p.route_authority_hash<>r.route_authority_hash THEN
    RAISE EXCEPTION 'R1C compile blocked: profile not current for route';
  END IF;

  SELECT * INTO c
  FROM retail.search_compiler_versions
  WHERE id=p_compiler_version_id
    AND certification_status='certified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1C compile blocked: compiler not certified';
  END IF;

  IF c.compiler_authority_sha256<>
     retail.r1c_sha256_jsonb(
       retail.r1c_compiler_authority_document(c)
     ) THEN
    RAISE EXCEPTION 'R1C compiler authority fingerprint mismatch';
  END IF;

  IF c.query_builder_function_sha256<>
       retail.r1c_function_sha256(
         'retail.r1c_build_query_v3(text,text,jsonb,jsonb)'::regprocedure
       )
     OR c.input_validator_function_sha256<>
       retail.r1c_function_sha256(
         'retail.r1c_validate_input_contract(jsonb,text,jsonb)'::regprocedure
       )
     OR c.scraper_authority_function_sha256<>
       retail.r1c_function_sha256(
         'retail.r1c_scraper_authority_document(uuid)'::regprocedure
       )
     OR c.binding_current_function_sha256<>
       retail.r1c_function_sha256(
         'retail.r1c_r1b_binding_is_current()'::regprocedure
       )
     OR c.profile_document_function_sha256<>
       retail.r1c_function_sha256(
         'retail.r1c_compile_profile_document(retail.search_route_compile_profiles)'::regprocedure
       ) THEN
    RAISE EXCEPTION 'R1C compiler helper/function drift detected';
  END IF;

  IF c.normalized_job_function_sha256<>
       retail.r1c_function_sha256(
         'retail.r1c_normalized_job_document(uuid,uuid)'::regprocedure
       )
     OR c.adapter_payload_function_sha256<>
       retail.r1c_function_sha256(
         'retail.r1c_adapter_payload_document(uuid,uuid)'::regprocedure
       )
     OR c.compile_route_function_sha256<>
       retail.r1c_function_sha256(
         'retail.r1c_compile_route(uuid,uuid,uuid,uuid,text,text)'::regprocedure
       )
     OR c.currentness_function_sha256<>
       retail.r1c_function_sha256(
         'retail.r1c_compilation_is_current(uuid)'::regprocedure
       ) THEN
    RAISE EXCEPTION 'R1C compiler SQL implementation drift detected';
  END IF;

  v_scraper:=retail.r1c_scraper_authority_document(r.adapter_id);
  IF COALESCE((v_scraper->>'execution_ready')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'R1C scraper authority document is not execution-ready';
  END IF;

  v_normalized:=retail.r1c_normalized_job_document(
    p_route_id,p_profile_id
  );
  v_payload:=retail.r1c_adapter_payload_document(
    p_route_id,p_profile_id
  );

  v_evidence:=jsonb_build_object(
    'r1b_certification_binding',
      (SELECT to_jsonb(b)
       FROM retail.r1c_r1b_certification_binding b
       WHERE singleton=true),
    'route_authority_hash',r.route_authority_hash,
    'r1a_revision_hash',r.r1a_revision_hash,
    'compile_profile_sha256',p.profile_sha256,
    'adapter_implementation_sha256',r.implementation_sha256,
    'adapter_input_contract_sha256',r.input_contract_sha256,
    'adapter_capability_sha256',r.capability_sha256,
    'adapter_certification_fingerprint_hash',
      r.certification_fingerprint_hash,
    'scraper_authority',v_scraper,
    'compiler_authority_sha256',c.compiler_authority_sha256
  );

  v_key:=retail.r1c_sha256_text(
    r.route_authority_hash||':'||
    p.profile_sha256||':'||
    c.compiler_authority_sha256||':'||
    retail.r1c_sha256_jsonb(v_normalized)||':'||
    retail.r1c_sha256_jsonb(v_payload)
  );

  INSERT INTO retail.search_job_compilations(
    compilation_key,
    route_id,route_authority_hash,
    compile_profile_id,compile_profile_sha256,
    target_id,r1a_revision_id,r1a_revision_hash,
    platform_id,collection_source_id,adapter_id,location_id,
    compiler_version_id,compiler_authority_sha256,
    normalized_job_json,normalized_job_sha256,
    adapter_payload_json,adapter_payload_sha256,
    compilation_evidence_json,compilation_evidence_sha256,
    source_process_run_id,source_correlation_id,compiled_by
  )
  VALUES(
    v_key,
    r.route_id,r.route_authority_hash,
    p.id,p.profile_sha256,
    r.target_id,r.r1a_revision_id,r.r1a_revision_hash,
    r.platform_id,r.collection_source_id,r.adapter_id,r.location_id,
    c.id,c.compiler_authority_sha256,
    v_normalized,retail.r1c_sha256_jsonb(v_normalized),
    v_payload,retail.r1c_sha256_jsonb(v_payload),
    v_evidence,retail.r1c_sha256_jsonb(v_evidence),
    p_process_run_id,p_correlation_id,p_actor
  )
  ON CONFLICT(compilation_key) DO UPDATE
    SET compilation_key=EXCLUDED.compilation_key
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION retail.r1c_certify_compiler(
  p_compiler_id uuid,
  p_qa_evidence_sha256 text,
  p_process_run_id uuid,
  p_correlation_id text,
  p_certifier text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  c retail.search_compiler_versions%ROWTYPE;
  v_authority text;
BEGIN
  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id',p_certifier,true);
  PERFORM set_config('app.actor_name',p_certifier,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  IF p_qa_evidence_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid QA evidence SHA';
  END IF;

  SELECT * INTO c
  FROM retail.search_compiler_versions
  WHERE id=p_compiler_id
  FOR UPDATE;

  IF NOT FOUND OR c.certification_status<>'uncertified' THEN
    RAISE EXCEPTION 'Compiler missing or not eligible';
  END IF;

  IF c.hardening_migration_sha256 IS NULL THEN
    RAISE EXCEPTION 'R1C V3 hardening migration SHA required';
  END IF;

  IF c.compiler_contract_sha256<>
     retail.r1c_sha256_jsonb(c.compiler_contract_json) THEN
    RAISE EXCEPTION 'Compiler contract SHA mismatch';
  END IF;

  UPDATE retail.search_compiler_versions
  SET normalized_job_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_normalized_job_document(uuid,uuid)'::regprocedure
        ),
      adapter_payload_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_adapter_payload_document(uuid,uuid)'::regprocedure
        ),
      compile_route_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_compile_route(uuid,uuid,uuid,uuid,text,text)'::regprocedure
        ),
      currentness_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_compilation_is_current(uuid)'::regprocedure
        ),
      query_builder_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_build_query_v3(text,text,jsonb,jsonb)'::regprocedure
        ),
      input_validator_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_validate_input_contract(jsonb,text,jsonb)'::regprocedure
        ),
      scraper_authority_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_scraper_authority_document(uuid)'::regprocedure
        ),
      binding_current_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_r1b_binding_is_current()'::regprocedure
        ),
      profile_document_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_compile_profile_document(retail.search_route_compile_profiles)'::regprocedure
        ),
      qa_evidence_sha256=p_qa_evidence_sha256,
      source_process_run_id=p_process_run_id,
      source_correlation_id=p_correlation_id
  WHERE id=p_compiler_id
    AND certification_status='uncertified';

  SELECT retail.r1c_sha256_jsonb(
           retail.r1c_compiler_authority_document(x)
         )
    INTO v_authority
  FROM retail.search_compiler_versions x
  WHERE id=p_compiler_id;

  UPDATE retail.search_compiler_versions
  SET compiler_authority_sha256=v_authority,
      certification_status='certified',
      certified_by=p_certifier,
      certified_at=now()
  WHERE id=p_compiler_id
    AND certification_status='uncertified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Compiler certification state transition failed';
  END IF;

  SELECT * INTO c
  FROM retail.search_compiler_versions
  WHERE id=p_compiler_id;

  IF c.compiler_authority_sha256<>
     retail.r1c_sha256_jsonb(
       retail.r1c_compiler_authority_document(c)
     ) THEN
    RAISE EXCEPTION 'Compiler authority SHA failed post-certification verification';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION retail.r1c_assert_runtime_compiler_v3(
  p_compiler_id uuid,
  p_observed_typescript_sha256 text,
  p_observed_sql_migration_sha256 text,
  p_observed_hardening_migration_sha256 text
)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  c retail.search_compiler_versions%ROWTYPE;
BEGIN
  SELECT * INTO c
  FROM retail.search_compiler_versions
  WHERE id=p_compiler_id
    AND certification_status='certified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1C V3 runtime compiler not certified';
  END IF;

  IF c.typescript_wrapper_sha256<>p_observed_typescript_sha256
     OR c.sql_migration_sha256<>p_observed_sql_migration_sha256
     OR c.hardening_migration_sha256<>p_observed_hardening_migration_sha256 THEN
    RAISE EXCEPTION 'R1C V3 runtime compiler artifact SHA mismatch';
  END IF;

  IF c.compiler_authority_sha256<>
     retail.r1c_sha256_jsonb(
       retail.r1c_compiler_authority_document(c)
     ) THEN
    RAISE EXCEPTION 'R1C V3 runtime compiler authority fingerprint mismatch';
  END IF;
END $$;
CREATE OR REPLACE FUNCTION retail.r1c_assert_runtime_compiler_v3(
  p_compiler_id uuid,
  p_observed_typescript_sha256 text,
  p_observed_sql_migration_sha256 text,
  p_observed_hardening_migration_sha256 text
)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  c retail.search_compiler_versions%ROWTYPE;
BEGIN
  SELECT * INTO c
  FROM retail.search_compiler_versions
  WHERE id=p_compiler_id
    AND certification_status='certified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1C V3 runtime compiler not certified';
  END IF;

  IF c.typescript_wrapper_sha256<>p_observed_typescript_sha256
     OR c.sql_migration_sha256<>p_observed_sql_migration_sha256
     OR c.hardening_migration_sha256<>p_observed_hardening_migration_sha256 THEN
    RAISE EXCEPTION 'R1C V3 runtime compiler artifact SHA mismatch';
  END IF;

  IF retail.r1c_compiler_functions_current(c.id) IS NOT TRUE THEN
    RAISE EXCEPTION 'R1C V3 runtime compiler function drift detected';
  END IF;

  IF c.compiler_authority_sha256<>
     retail.r1c_sha256_jsonb(
       retail.r1c_compiler_authority_document(c)
     ) THEN
    RAISE EXCEPTION 'R1C V3 runtime compiler authority fingerprint mismatch';
  END IF;
END $$;

COMMIT;
