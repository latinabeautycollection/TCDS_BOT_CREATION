BEGIN;

DROP INDEX retail.uq_r1e_v2_capture_ruleset_upstream;
DROP INDEX retail.uq_r1e_v2_one_qualified_observation;

CREATE UNIQUE INDEX uq_r1e_v2_capture_ruleset_upstream
ON retail.r1e_qualification_results(
  raw_capture_id,
  ruleset_id,
  r1d_certification_run_id,
  certification_fixture
)
WHERE r1d_certification_run_id IS NOT NULL;

CREATE UNIQUE INDEX uq_r1e_v2_one_qualified_observation
ON retail.r1e_qualification_results(
  ruleset_id,
  r1d_certification_run_id,
  observation_fingerprint,
  certification_fixture
)
WHERE decision='QUALIFIED'
  AND observation_fingerprint IS NOT NULL
  AND r1d_certification_run_id IS NOT NULL;

CREATE OR REPLACE FUNCTION retail.r1e_evaluate_capture_v21(p_raw_capture_id uuid, p_ruleset_id uuid, p_process_run_id uuid, p_correlation_id text, p_actor text, p_certification_fixture boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'retail', 'arb'
AS $function$
DECLARE
  cap retail.raw_product_captures%ROWTYPE;
  rp retail.retail_products%ROWTYPE;
  comp retail.search_job_compilations%ROWTYPE;
  attempt retail.r1d_dispatch_attempts%ROWTYPE;
  bind retail.r1e_r1d_certification_binding%ROWTYPE;
  rs retail.r1e_match_rulesets%ROWTYPE;

  v_target jsonb;
  v_returned jsonb;
  v_match jsonb;
  v_attempt_id bigint;
  v_attempt_evidence jsonb;
  v_attempt_sha text;
  v_product_fp text;
  v_observation_doc jsonb;
  v_observation_fp text;
  v_duplicate uuid;
  v_evidence jsonb;
  v_id uuid;
BEGIN
  PERFORM retail.r1e_assert_process_run(
    p_process_run_id,
    CASE WHEN p_certification_fixture THEN
      ARRAY[
        'RETAIL_R1E_V21_E2E_CERTIFY',
        'RETAIL_R1E_V21_DUPLICATE_RACE'
      ]
    ELSE
      ARRAY[
        'RETAIL_R1E_QUALIFY_CAPTURE',
        'RETAIL_R1E_QUALIFY_BATCH'
      ]
    END
  );

  PERFORM set_config(
    'app.actor_type',
    CASE WHEN p_certification_fixture THEN 'system' ELSE 'worker' END,
    true
  );
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  IF retail.r1e_r1d_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1E V2.1 evaluation blocked: R1D binding stale';
  END IF;

  SELECT * INTO bind
  FROM retail.r1e_r1d_certification_binding
  WHERE singleton=true;

  SELECT * INTO rs
  FROM retail.r1e_match_rulesets
  WHERE id=p_ruleset_id
    AND certification_status='certified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1E V2.1 requires certified ruleset';
  END IF;

  PERFORM retail.r1e_validate_ruleset_v2(rs.rules_json);

  IF rs.rules_sha256<>retail.r1e_sha256_jsonb(rs.rules_json) THEN
    RAISE EXCEPTION 'R1E V2.1 ruleset SHA mismatch';
  END IF;

  SELECT * INTO cap
  FROM retail.raw_product_captures
  WHERE id=p_raw_capture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1E V2.1 raw capture missing';
  END IF;

  v_attempt_id:=retail.r1e_resolve_attempt_for_capture(cap.id);

  SELECT * INTO attempt
  FROM retail.r1d_dispatch_attempts
  WHERE id=v_attempt_id;

  SELECT j.*
  INTO comp
  FROM retail.r1d_dispatch_jobs dj
  JOIN retail.search_job_compilations j
    ON j.id=dj.compilation_id
  WHERE dj.id=attempt.job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1E V2.1 immutable R1C compilation snapshot missing';
  END IF;

  -- Exact immutable R1A revision is the product-identity authority.
  v_target:=retail.r1e_r1a_revision_identity_document(
    comp.r1a_revision_id,
    comp.r1a_revision_hash
  );

  IF (v_target->>'target_id')::uuid IS DISTINCT FROM comp.target_id THEN
    RAISE EXCEPTION 'R1E V2.1 R1A target/revision mismatch';
  END IF;

  SELECT p.*
  INTO rp
  FROM retail.retail_products p
  WHERE p.platform_id=cap.platform_id
    AND p.platform_product_key=cap.platform_product_key
  ORDER BY p.last_seen_at DESC,p.id::text DESC
  LIMIT 1;

  v_returned:=jsonb_strip_nulls(jsonb_build_object(
    'platform_product_key',cap.platform_product_key,
    'retail_product_id',rp.id,
    'title',COALESCE(rp.title,cap.raw_title),
    'brand',COALESCE(rp.brand,cap.raw_brand),
    'model_number',NULLIF(
      COALESCE(
        rp.model_number,
        rp.normalized_json->>'model',
        rp.normalized_json->>'model_number',
        cap.raw_payload->>'model',
        cap.raw_payload->>'model_number'
      ),
      cap.platform_product_key
    ),
    'upc',rp.upc,
    'ean',rp.ean,
    'asin',rp.asin,
    'sku',rp.sku,
    'condition',COALESCE(
      rp.normalized_json->>'condition',
      cap.raw_payload->>'condition',
      cap.capture_metadata->>'condition'
    ),
    'normalized_json',rp.normalized_json,
    'normalized_identity',jsonb_strip_nulls(jsonb_build_object(
      'normalized_product_type',COALESCE(
        rp.normalized_json->>'normalized_product_type',
        cap.raw_payload->>'normalized_product_type'
      ),
      'normalized_model_token',NULLIF(
        COALESCE(
          rp.normalized_json->>'normalized_model_token',
          rp.model_number
        ),
        cap.platform_product_key
      ),
      'generation',COALESCE(
        rp.normalized_json->>'normalized_generation',
        rp.normalized_json->>'generation',
        cap.raw_payload->>'generation'
      ),
      'variant',COALESCE(
        rp.normalized_json->>'normalized_variant',
        rp.normalized_json->>'variant',
        cap.raw_payload->>'variant'
      ),
      'storage',COALESCE(
        rp.normalized_json->>'normalized_storage',
        rp.normalized_json->>'storage',
        cap.raw_payload->>'storage'
      ),
      'ram',COALESCE(
        rp.normalized_json->>'normalized_ram',
        rp.normalized_json->>'ram',
        cap.raw_payload->>'ram'
      ),
      'platform',COALESCE(
        rp.normalized_json->>'normalized_platform',
        rp.normalized_json->>'platform',
        cap.raw_payload->>'platform'
      )
    )),
    'source_url',cap.source_url
  ));

  v_attempt_evidence:=retail.r1e_attempt_evidence_document(attempt.id);
  v_attempt_sha:=retail.r1e_sha256_jsonb(v_attempt_evidence);

  v_product_fp:=retail.r1e_sha256_jsonb(
    jsonb_strip_nulls(jsonb_build_object(
      'platform_id',cap.platform_id,
      'platform_product_key',cap.platform_product_key,
      'upc',rp.upc,
      'ean',rp.ean,
      'asin',rp.asin,
      'sku',rp.sku,
      'normalized_title',
        retail.r1e_normalize_text(COALESCE(rp.title,cap.raw_title)),
      'normalized_model',
        retail.r1e_normalize_text(NULLIF(
          COALESCE(
            rp.model_number,
            rp.normalized_json->>'model',
            cap.raw_payload->>'model'
          ),
          cap.platform_product_key
        ))
    ))
  );

  v_observation_doc:=retail.r1e_observation_document_v21(
    cap,comp,rp
  );
  v_observation_fp:=retail.r1e_sha256_jsonb(v_observation_doc - 'collection_run_id');

  -- Full production duplicate race is serialized here.
  PERFORM pg_advisory_xact_lock(
    retail.r1e_observation_lock_key(v_observation_fp)
  );

  SELECT q.id
  INTO v_duplicate
  FROM retail.r1e_qualification_results q
  WHERE q.ruleset_id=p_ruleset_id
    AND q.r1d_certification_run_id=bind.r1d_certification_run_id
    AND q.observation_fingerprint=v_observation_fp
    AND q.raw_capture_id<>p_raw_capture_id
    AND q.engine_version='r1e-v2.1.0'
    AND q.decision='QUALIFIED'
  ORDER BY q.qualified_at,q.id::text
  LIMIT 1;

  IF rp.id IS NULL THEN
    v_match:=jsonb_build_object(
      'decision','REJECTED_INCOMPLETE',
      'reason_codes',jsonb_build_array(
        'CANONICAL_RETAIL_PRODUCT_MISSING'
      ),
      'variant_match',jsonb_build_object('hard_match',false),
      'identifier_match',jsonb_build_object('hard_match',true),
      'scores',jsonb_build_object(
        'brand',0,'model',0,'title',0,'identifier',0,
        'identity',0,'accessory',0,'condition',0,'confidence',0
      )
    );
  ELSE
    v_match:=retail.r1e_match_documents_v21(
      v_target,v_returned,rs.rules_json,v_duplicate IS NOT NULL
    );
  END IF;

  v_evidence:=jsonb_build_object(
    'engine_version','r1e-v2.1.0',
    'r1d_certification_run_id',bind.r1d_certification_run_id,
    'r1d_package_sha256',bind.r1d_package_sha256,
    'r1d_attempt_evidence',v_attempt_evidence,
    'r1d_attempt_evidence_sha256',v_attempt_sha,
    'r1c_compilation_id',comp.id,
    'r1c_compilation_key',comp.compilation_key,
    'route_id',comp.route_id,
    'route_authority_hash',comp.route_authority_hash,
    'r1a_revision_id',comp.r1a_revision_id,
    'r1a_revision_hash',comp.r1a_revision_hash,
    'collection_run_id',cap.collection_run_id,
    'raw_payload_hash',cap.payload_hash,
    'ruleset_id',rs.id,
    'ruleset_sha256',rs.rules_sha256,
    'target_identity',v_target,
    'returned_identity',v_returned,
    'product_identity_fingerprint',v_product_fp,
    'observation_context',v_observation_doc,
    'observation_fingerprint',v_observation_fp,
    'duplicate_of_result_id',v_duplicate,
    'match',v_match,
    'certification_fixture',p_certification_fixture
  );

  BEGIN
    INSERT INTO retail.r1e_qualification_results(
      raw_capture_id,retail_product_id,platform_id,
      compilation_id,route_id,target_id,ruleset_id,
      returned_identity_json,target_identity_json,
      identity_score,accessory_score,condition_score,confidence_score,
      duplicate_fingerprint,duplicate_of_result_id,
      decision,reason_codes,evidence_json,evidence_sha256,
      source_process_run_id,source_correlation_id,qualified_by,
      r1d_certification_run_id,r1d_package_sha256,
      r1c_compilation_key,route_authority_hash,
      r1a_revision_id,r1a_revision_hash,
      ruleset_sha256,engine_version,
      product_identity_fingerprint,observation_fingerprint,
      observation_context_json,
      r1d_attempt_evidence_json,r1d_attempt_evidence_sha256,
      certification_fixture
    )
    VALUES(
      p_raw_capture_id,rp.id,cap.platform_id,
      comp.id,comp.route_id,comp.target_id,p_ruleset_id,
      v_returned,v_target,
      COALESCE((v_match#>>'{scores,identity}')::numeric,0),
      COALESCE((v_match#>>'{scores,accessory}')::numeric,0),
      COALESCE((v_match#>>'{scores,condition}')::numeric,0),
      COALESCE((v_match#>>'{scores,confidence}')::numeric,0),
      v_observation_fp,v_duplicate,
      v_match->>'decision',
      COALESCE(v_match->'reason_codes','[]'::jsonb),
      v_evidence,retail.r1e_sha256_jsonb(v_evidence),
      p_process_run_id,p_correlation_id,p_actor,
      bind.r1d_certification_run_id,bind.r1d_package_sha256,
      comp.compilation_key,comp.route_authority_hash,
      comp.r1a_revision_id,comp.r1a_revision_hash,
      rs.rules_sha256,'r1e-v2.1.0',
      v_product_fp,v_observation_fp,v_observation_doc,
      v_attempt_evidence,v_attempt_sha,
      p_certification_fixture
    )
    ON CONFLICT(
      raw_capture_id,ruleset_id,r1d_certification_run_id,
      certification_fixture
    )
    WHERE r1d_certification_run_id IS NOT NULL
    DO NOTHING
    RETURNING id INTO v_id;

  EXCEPTION WHEN unique_violation THEN
    -- A concurrent evaluator committed the same qualified observation after
    -- this statement took its READ COMMITTED snapshot. The partial unique
    -- index is the final concurrency authority. Persist this row as duplicate.
    SELECT q.id
    INTO v_duplicate
    FROM retail.r1e_qualification_results q
    WHERE q.ruleset_id=p_ruleset_id
      AND q.r1d_certification_run_id=bind.r1d_certification_run_id
      AND q.observation_fingerprint=v_observation_fp
      AND q.decision='QUALIFIED'
      AND q.certification_fixture=p_certification_fixture
    ORDER BY q.qualified_at,q.id::text
    LIMIT 1;

    v_match:=v_match||jsonb_build_object(
      'decision','REJECTED_DUPLICATE',
      'reason_codes',
        COALESCE(v_match->'reason_codes','[]'::jsonb)
        || jsonb_build_array('DUPLICATE_OBSERVATION')
    );

    v_evidence:=jsonb_set(
      jsonb_set(
        v_evidence,
        '{match}',
        v_match,
        true
      ),
      '{duplicate_of_result_id}',
      to_jsonb(v_duplicate),
      true
    );

    INSERT INTO retail.r1e_qualification_results(
      raw_capture_id,retail_product_id,platform_id,
      compilation_id,route_id,target_id,ruleset_id,
      returned_identity_json,target_identity_json,
      identity_score,accessory_score,condition_score,confidence_score,
      duplicate_fingerprint,duplicate_of_result_id,
      decision,reason_codes,evidence_json,evidence_sha256,
      source_process_run_id,source_correlation_id,qualified_by,
      r1d_certification_run_id,r1d_package_sha256,
      r1c_compilation_key,route_authority_hash,
      r1a_revision_id,r1a_revision_hash,
      ruleset_sha256,engine_version,
      product_identity_fingerprint,observation_fingerprint,
      observation_context_json,
      r1d_attempt_evidence_json,r1d_attempt_evidence_sha256,
      certification_fixture
    )
    VALUES(
      p_raw_capture_id,rp.id,cap.platform_id,
      comp.id,comp.route_id,comp.target_id,p_ruleset_id,
      v_returned,v_target,
      COALESCE((v_match#>>'{scores,identity}')::numeric,0),
      COALESCE((v_match#>>'{scores,accessory}')::numeric,0),
      COALESCE((v_match#>>'{scores,condition}')::numeric,0),
      COALESCE((v_match#>>'{scores,confidence}')::numeric,0),
      v_observation_fp,v_duplicate,
      'REJECTED_DUPLICATE',
      COALESCE(v_match->'reason_codes','[]'::jsonb),
      v_evidence,retail.r1e_sha256_jsonb(v_evidence),
      p_process_run_id,p_correlation_id,p_actor,
      bind.r1d_certification_run_id,bind.r1d_package_sha256,
      comp.compilation_key,comp.route_authority_hash,
      comp.r1a_revision_id,comp.r1a_revision_hash,
      rs.rules_sha256,'r1e-v2.1.0',
      v_product_fp,v_observation_fp,v_observation_doc,
      v_attempt_evidence,v_attempt_sha,
      p_certification_fixture
    )
    ON CONFLICT(
      raw_capture_id,ruleset_id,r1d_certification_run_id,
      certification_fixture
    )
    WHERE r1d_certification_run_id IS NOT NULL
    DO NOTHING
    RETURNING id INTO v_id;
  END;

  IF v_id IS NULL THEN
    SELECT id INTO v_id
    FROM retail.r1e_qualification_results
    WHERE raw_capture_id=p_raw_capture_id
      AND ruleset_id=p_ruleset_id
      AND r1d_certification_run_id=bind.r1d_certification_run_id
      AND certification_fixture=p_certification_fixture;
  END IF;

  RETURN v_id;
END $function$;

COMMIT;
