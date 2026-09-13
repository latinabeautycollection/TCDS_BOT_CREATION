BEGIN;

CREATE OR REPLACE FUNCTION retail.r1c_adapter_payload_document(
  p_route_id uuid,
  p_profile_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  r record;
  p retail.search_route_compile_profiles%ROWTYPE;
  v_contract jsonb;
  v_payload jsonb:='{}'::jsonb;
  v_values jsonb:='{}'::jsonb;
  v_query text;
  v_field text;
  v_target_name text;
BEGIN
  SELECT * INTO r
  FROM retail.effective_search_routes
  WHERE route_id=p_route_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1C compile blocked: route not effective';
  END IF;

  IF retail.r1b_adapter_execution_ready(r.adapter_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'R1C compile blocked: adapter/scraper not execution-ready';
  END IF;

  SELECT * INTO p
  FROM retail.search_route_compile_profiles
  WHERE id=p_profile_id
    AND route_id=p_route_id
    AND profile_status='active';

  IF NOT FOUND
     OR p.route_authority_hash<>r.route_authority_hash
     OR p.profile_sha256<>
        retail.r1c_sha256_jsonb(retail.r1c_compile_profile_document(p)) THEN
    RAISE EXCEPTION 'R1C compile blocked: compile profile stale/invalid';
  END IF;

  v_contract:=r.input_contract_json;

  IF p.contract_required_fields IS DISTINCT FROM
     COALESCE(v_contract->'required_fields','[]'::jsonb) THEN
    RAISE EXCEPTION
      'R1C compile blocked: profile does not bind current certified contract required_fields';
  END IF;

  IF p.effective_required_fields<>
     retail.r1c_jsonb_text_union(
       p.contract_required_fields,p.required_fields
     ) THEN
    RAISE EXCEPTION 'R1C compile blocked: effective required fields drift';
  END IF;

  PERFORM retail.r1c_validate_input_contract(
    v_contract,p.compile_mode,p.effective_required_fields
  );

  IF p.compile_mode='keyword'
     AND r.supports_keyword_search IS NOT TRUE THEN
    RAISE EXCEPTION 'Keyword compile mode unsupported';
  ELSIF p.compile_mode='category'
     AND r.supports_category_search IS NOT TRUE THEN
    RAISE EXCEPTION 'Category compile mode unsupported';
  ELSIF p.compile_mode='product_url'
     AND r.supports_product_url IS NOT TRUE THEN
    RAISE EXCEPTION 'Product URL compile mode unsupported';
  ELSIF p.compile_mode='store_inventory'
     AND r.supports_store_id IS NOT TRUE THEN
    RAISE EXCEPTION 'Store inventory compile mode unsupported';
  END IF;

  v_query:=retail.r1c_build_query_v3(
    r.brand,r.model_family,r.include_terms,p.query_policy
  );

  IF p.compile_mode='keyword' THEN
    IF NULLIF(v_query,'') IS NULL THEN
      RAISE EXCEPTION 'No deterministic query available';
    END IF;
    v_values:=v_values||jsonb_build_object('query',v_query);
  ELSIF p.compile_mode='category' THEN
    IF NULLIF(r.category_key,'') IS NULL THEN
      RAISE EXCEPTION 'category_key missing';
    END IF;
    v_values:=v_values||jsonb_build_object('category',r.category_key);
  ELSIF p.compile_mode='product_url' THEN
    IF NULLIF(r.routing_policy->>'product_url','') IS NULL THEN
      RAISE EXCEPTION 'routing_policy.product_url missing';
    END IF;
    v_values:=v_values||jsonb_build_object(
      'product_url',r.routing_policy->>'product_url'
    );
  ELSIF p.compile_mode='store_inventory' THEN
    IF r.location_type<>'store'
       OR r.retailer_store_id IS NULL THEN
      RAISE EXCEPTION 'store_inventory requires store location/store id';
    END IF;
  END IF;

  -- Optional location/result fields are emitted ONLY when both a certified
  -- mapping exists and the corresponding certified capability is true.
  IF r.location_type='store'
     AND r.retailer_store_id IS NOT NULL
     AND r.supports_store_id IS TRUE
     AND NULLIF(v_contract#>>'{field_map,store_id}','') IS NOT NULL THEN
    v_values:=v_values||jsonb_build_object(
      'store_id',r.retailer_store_id
    );
  END IF;

  IF r.postal_code IS NOT NULL
     AND r.supports_postal_code IS TRUE
     AND NULLIF(v_contract#>>'{field_map,postal_code}','') IS NOT NULL THEN
    v_values:=v_values||jsonb_build_object(
      'postal_code',r.postal_code
    );
  END IF;

  IF r.location_type='region'
     AND r.supports_region IS TRUE
     AND NULLIF(v_contract#>>'{field_map,region}','') IS NOT NULL THEN
    v_values:=v_values||jsonb_build_object(
      'region',COALESCE(r.state_code,r.display_name)
    );
  END IF;

  IF r.supports_result_limit IS TRUE
     AND NULLIF(v_contract#>>'{field_map,result_limit}','') IS NOT NULL THEN
    v_values:=v_values||jsonb_build_object(
      'result_limit',r.discovery_result_limit
    );
  END IF;

  FOR v_field IN
    SELECT jsonb_array_elements_text(p.effective_required_fields)
  LOOP
    IF NULLIF(v_values->>v_field,'') IS NULL THEN
      RAISE EXCEPTION 'Required compile value % missing for route',v_field;
    END IF;
  END LOOP;

  FOR v_field,v_target_name IN
    SELECT key,value FROM jsonb_each_text(v_contract->'field_map')
  LOOP
    IF v_values ? v_field THEN
      v_payload:=v_payload||
        jsonb_build_object(v_target_name,v_values->v_field);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'transport',v_contract->>'transport',
    'compile_mode',p.compile_mode,
    'parameters',v_payload,
    'collection',jsonb_strip_nulls(jsonb_build_object(
      'collection_method',r.collection_method,
      'source_url',r.source_url,
      'dataset_id',r.dataset_id,
      'unlocker_zone',r.unlocker_zone,
      'request_overrides',r.request_overrides,
      'pagination_policy',r.pagination_policy
    )),
    'constraints',jsonb_strip_nulls(jsonb_build_object(
      'exclude_terms',r.exclude_terms,
      'allowed_product_conditions',r.allowed_product_conditions,
      'discovery_price_ceiling_usd',r.discovery_price_ceiling_usd
    ))
  );
END $$;

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
  p retail.search_route_compile_profiles%ROWTYPE;
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

COMMENT ON FUNCTION
  retail.r1c_adapter_payload_document(uuid,uuid)
IS
  'R1C V3 payload compiler using a typed compile-profile row.';

COMMENT ON FUNCTION
  retail.r1c_compile_route(uuid,uuid,uuid,uuid,text,text)
IS
  'R1C V3 route compiler using typed profile and compiler rows.';

COMMIT;
