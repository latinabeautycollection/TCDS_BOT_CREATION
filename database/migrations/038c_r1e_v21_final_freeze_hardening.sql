BEGIN;

-- ============================================================================
-- TCDS RETAIL R1E V2.1 — GREEN TIER 1 FINAL FREEZE
-- Exact Product Identity + Observation Qualification
-- Fortune-500 production hardening over R1E V2
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('retail.r1e_v2_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1e_v2_state
       WHERE singleton=true AND hardening_version='2.0.0'
     ) THEN
    RAISE EXCEPTION 'R1E V2.1 requires installed R1E V2 hardening 2.0.0';
  END IF;

  IF to_regclass('retail.r1a_schema_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1a_schema_state
       WHERE singleton=true AND schema_version='2.0.0'
     ) THEN
    RAISE EXCEPTION 'R1E V2.1 requires R1A V2 exact revision authority';
  END IF;

  IF to_regclass('retail.search_target_revisions') IS NULL
     OR to_regprocedure('retail.r1a_revision_business_document(retail.search_target_revisions)') IS NULL THEN
    RAISE EXCEPTION 'R1E V2.1 requires immutable R1A revision/hash functions';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS retail.r1e_v21_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  hardening_version text NOT NULL,
  doctrine text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user
);

INSERT INTO retail.r1e_v21_state(singleton,hardening_version,doctrine)
VALUES(
  true,'2.1.0',
  'R1E V2.1 is the final exact-product identity and observation authority. It revokes legacy execution paths, binds immutable R1A revisions directly, separates required identity terms from search expansion terms, canonicalizes variant attributes, fails closed on ambiguous lineage, and requires full evaluator QA plus concurrency certification.'
)
ON CONFLICT(singleton) DO UPDATE SET
  hardening_version=EXCLUDED.hardening_version,
  doctrine=EXCLUDED.doctrine;

-- ---------- LEGACY AUTHORITY REVOCATION -------------------------------------
-- V1 execution paths must not remain callable by R1E runtime/certifier roles.
REVOKE EXECUTE ON FUNCTION retail.r1e_evaluate_capture(uuid,uuid,uuid,text,text)
  FROM retail_r1e_worker,retail_r1e_certifier;
REVOKE EXECUTE ON FUNCTION retail.r1e_bind_r1d_certification(uuid,uuid,text,text)
  FROM retail_r1e_worker,retail_r1e_certifier;
REVOKE EXECUTE ON FUNCTION retail.r1e_certify_ruleset(uuid,jsonb,text)
  FROM retail_r1e_worker,retail_r1e_certifier;

-- V2 evaluator is superseded by V2.1 because it lacks direct R1A revision
-- verification and final end-to-end identity semantics.
REVOKE EXECUTE ON FUNCTION retail.r1e_evaluate_capture_v2(uuid,uuid,uuid,text,text)
  FROM retail_r1e_worker,retail_r1e_certifier;

-- ---------- PROCESS REGISTRY -------------------------------------------------
INSERT INTO arb.process_registry(
  process_name,phase_no,process_group,description,owner_team,active_flag
)
VALUES
('RETAIL_R1E_V21_E2E_CERTIFY',2,'RETAIL_AUTOMATION',
 'Run full production-evaluator QA fixtures through lineage, identity, persistence and currentness.',
 'TCDS Retail Automation',true),
('RETAIL_R1E_V21_DUPLICATE_RACE',2,'RETAIL_AUTOMATION',
 'Run full evaluator two-transaction duplicate race certification.',
 'TCDS Retail Automation',true)
ON CONFLICT(process_name) DO NOTHING;

-- ---------- EXACT R1A REVISION IDENTITY -------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_r1a_revision_identity_document(
  p_revision_id uuid,
  p_expected_revision_hash text
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  r retail.search_target_revisions%ROWTYPE;
  v_computed_hash text;
  v_required_terms jsonb;
  v_search_terms jsonb;
  v_required_attributes jsonb;
  v_identifiers jsonb;
BEGIN
  SELECT * INTO r
  FROM retail.search_target_revisions
  WHERE id=p_revision_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1E V2.1 R1A revision % does not exist',p_revision_id;
  END IF;

  IF r.revision_hash IS DISTINCT FROM p_expected_revision_hash THEN
    RAISE EXCEPTION
      'R1E V2.1 R1A revision hash mismatch: stored %, compilation %',
      r.revision_hash,p_expected_revision_hash;
  END IF;

  v_computed_hash:=retail.r1a_sha256_jsonb(
    retail.r1a_revision_business_document(r)
  );

  IF v_computed_hash<>r.revision_hash THEN
    RAISE EXCEPTION
      'R1E V2.1 immutable R1A revision document no longer reproduces revision hash';
  END IF;

  -- Search expansion terms are NOT hard product identity by default.
  v_search_terms:=COALESCE(
    r.search_policy->'search_expansion_terms',
    r.include_terms,
    '[]'::jsonb
  );

  -- Only explicitly governed required_identity_terms are hard qualification
  -- constraints. This prevents search synonyms from becoming false rejections.
  v_required_terms:=COALESCE(
    r.search_policy->'required_identity_terms',
    '[]'::jsonb
  );

  v_required_attributes:=COALESCE(
    r.search_policy->'required_identity_attributes',
    '{}'::jsonb
  );

  v_identifiers:=COALESCE(
    r.search_policy->'expected_identifiers',
    '{}'::jsonb
  );

  IF jsonb_typeof(v_required_terms)<>'array' THEN
    RAISE EXCEPTION
      'R1E V2.1 R1A search_policy.required_identity_terms must be array';
  END IF;
  IF jsonb_typeof(v_search_terms)<>'array' THEN
    RAISE EXCEPTION
      'R1E V2.1 R1A search expansion terms must be array';
  END IF;
  IF jsonb_typeof(v_required_attributes)<>'object' THEN
    RAISE EXCEPTION
      'R1E V2.1 R1A search_policy.required_identity_attributes must be object';
  END IF;
  IF jsonb_typeof(v_identifiers)<>'object' THEN
    RAISE EXCEPTION
      'R1E V2.1 R1A search_policy.expected_identifiers must be object';
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'r1a_revision_id',r.id,
    'r1a_revision_hash',r.revision_hash,
    'target_id',r.target_id,
    'revision_no',r.revision_no,
    'canonical_product_key',r.canonical_product_key,
    'brand',r.brand,
    'model_family',r.model_family,
    'category_key',r.category_key,
    'family_key',r.family_key,
    'family_name',r.family_name,
    'normalized_identity',jsonb_strip_nulls(
      jsonb_build_object(
        'normalized_product_type',r.normalized_product_type,
        'normalized_model_token',r.normalized_model_token,
        'generation',r.normalized_generation,
        'variant',r.normalized_variant,
        'storage',r.normalized_storage,
        'platform',r.normalized_platform
      ) || v_required_attributes
    ),
    'required_identity_terms',v_required_terms,
    'search_expansion_terms',v_search_terms,
    'exclude_terms',r.exclude_terms,
    'allowed_product_conditions',r.allowed_conditions,
    'identifiers',v_identifiers,
    'search_policy',r.search_policy,
    'upstream_identity_confidence',r.upstream_identity_confidence
  ));
END $$;

-- ---------- CANONICAL ATTRIBUTE NORMALIZATION -------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_normalize_capacity(p_value text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  m text[];
  n numeric;
  u text;
  gb numeric;
BEGIN
  IF p_value IS NULL THEN RETURN NULL; END IF;

  m:=regexp_match(
    lower(trim(p_value)),
    '([0-9]+(?:\.[0-9]+)?)\s*(tb|gb|mb)'
  );
  IF m IS NULL THEN
    RETURN retail.r1e_normalize_text(p_value);
  END IF;

  n:=m[1]::numeric;
  u:=m[2];

  gb:=CASE u
    WHEN 'tb' THEN n*1000
    WHEN 'gb' THEN n
    WHEN 'mb' THEN n/1000
  END;

  RETURN CASE
    WHEN gb=trunc(gb) THEN trunc(gb)::bigint::text||'gb'
    ELSE trim(trailing '0' FROM to_char(gb,'FM999999990.999'))||'gb'
  END;
END $$;

CREATE OR REPLACE FUNCTION retail.r1e_normalize_generation(p_value text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT NULLIF(
    trim(
      regexp_replace(
        regexp_replace(
          retail.r1e_normalize_text(p_value),
          '(^|\s)(generation|gen)(\s|$)',
          ' ',
          'g'
        ),
        '([0-9]+)(st|nd|rd|th)(\s|$)',
        '\1 ',
        'g'
      )
    ),
    ''
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1e_normalize_model_token(p_value text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT NULLIF(
    regexp_replace(
      lower(COALESCE(p_value,'')),
      '[^a-z0-9]+',
      '',
      'g'
    ),
    ''
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1e_normalize_platform(p_value text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v text:=retail.r1e_normalize_text(p_value);
BEGIN
  RETURN CASE
    WHEN v IN('ps5','playstation 5','sony playstation 5') THEN 'playstation 5'
    WHEN v IN('ps4','playstation 4','sony playstation 4') THEN 'playstation 4'
    WHEN v IN('xbox series x','series x') THEN 'xbox series x'
    WHEN v IN('xbox series s','series s') THEN 'xbox series s'
    WHEN v IN('nintendo switch','switch') THEN 'nintendo switch'
    WHEN v IN('ios','apple ios') THEN 'ios'
    WHEN v IN('android','google android') THEN 'android'
    WHEN v IN('mac os','macos','os x') THEN 'macos'
    WHEN v IN('windows 11','win11') THEN 'windows 11'
    ELSE v
  END;
END $$;

CREATE OR REPLACE FUNCTION retail.r1e_canonical_attribute_value(
  p_key text,
  p_value text
)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
  IF p_value IS NULL THEN RETURN NULL; END IF;

  RETURN CASE p_key
    WHEN 'storage' THEN retail.r1e_normalize_capacity(p_value)
    WHEN 'ram' THEN retail.r1e_normalize_capacity(p_value)
    WHEN 'generation' THEN retail.r1e_normalize_generation(p_value)
    WHEN 'platform' THEN retail.r1e_normalize_platform(p_value)
    WHEN 'normalized_model_token' THEN retail.r1e_normalize_model_token(p_value)
    ELSE retail.r1e_normalize_text(p_value)
  END;
END $$;

CREATE OR REPLACE FUNCTION retail.r1e_contains_canonical_attribute(
  p_text text,
  p_key text,
  p_expected text
)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_expected text:=retail.r1e_canonical_attribute_value(p_key,p_expected);
  m text[];
  v text;
BEGIN
  IF p_text IS NULL OR v_expected IS NULL THEN RETURN false; END IF;

  IF p_key='ram' THEN
    -- RAM fallback requires semantic context; do not let a storage capacity
    -- satisfy an expected RAM attribute.
    FOR m IN
      SELECT regexp_matches(
        lower(p_text),
        '([0-9]+(?:\.[0-9]+)?)\s*(tb|gb|mb)\s*(ram|memory)',
        'g'
      )
    LOOP
      v:=retail.r1e_normalize_capacity(m[1]||m[2]);
      IF v=v_expected THEN RETURN true; END IF;
    END LOOP;

    FOR m IN
      SELECT regexp_matches(
        lower(p_text),
        '(ram|memory)\s*([0-9]+(?:\.[0-9]+)?)\s*(tb|gb|mb)',
        'g'
      )
    LOOP
      v:=retail.r1e_normalize_capacity(m[2]||m[3]);
      IF v=v_expected THEN RETURN true; END IF;
    END LOOP;
    RETURN false;
  ELSIF p_key='storage' THEN
    -- Storage capacity is commonly published without an explicit "storage"
    -- token (phones/tablets), so a canonical bare capacity is acceptable.
    FOR m IN
      SELECT regexp_matches(
        lower(p_text),
        '([0-9]+(?:\.[0-9]+)?)\s*(tb|gb|mb)',
        'g'
      )
    LOOP
      v:=retail.r1e_normalize_capacity(m[1]||m[2]);
      IF v=v_expected THEN RETURN true; END IF;
    END LOOP;
    RETURN false;
  END IF;

  RETURN retail.r1e_contains_phrase(p_text,p_expected);
END $$;


CREATE OR REPLACE FUNCTION retail.r1e_returned_variant_attributes(
  p_returned jsonb
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_strip_nulls(
    COALESCE(p_returned->'normalized_identity','{}'::jsonb)
    || jsonb_build_object(
      'normalized_product_type',
        COALESCE(
          p_returned->>'normalized_product_type',
          p_returned#>>'{normalized_json,normalized_product_type}'
        ),
      'normalized_model_token',
        COALESCE(
          p_returned->>'normalized_model_token',
          p_returned#>>'{normalized_json,normalized_model_token}',
          p_returned->>'model_number'
        ),
      'generation',
        COALESCE(
          p_returned->>'generation',
          p_returned#>>'{normalized_json,normalized_generation}',
          p_returned#>>'{normalized_json,generation}'
        ),
      'variant',
        COALESCE(
          p_returned->>'variant',
          p_returned#>>'{normalized_json,normalized_variant}',
          p_returned#>>'{normalized_json,variant}'
        ),
      'storage',
        COALESCE(
          p_returned->>'storage',
          p_returned#>>'{normalized_json,normalized_storage}',
          p_returned#>>'{normalized_json,storage}'
        ),
      'ram',
        COALESCE(
          p_returned->>'ram',
          p_returned#>>'{normalized_json,normalized_ram}',
          p_returned#>>'{normalized_json,ram}'
        ),
      'platform',
        COALESCE(
          p_returned->>'platform',
          p_returned#>>'{normalized_json,normalized_platform}',
          p_returned#>>'{normalized_json,platform}'
        ),
      'canonical_product_key',
        COALESCE(
          p_returned->>'canonical_product_key',
          p_returned#>>'{normalized_json,canonical_product_key}'
        )
    )
  )
$$;


CREATE OR REPLACE FUNCTION retail.r1e_normalize_identity_phrase(
  p_value text
)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT NULLIF(
    regexp_replace(
      retail.r1e_normalize_text(p_value),
      '([0-9]+(?:\.[0-9]+)?)\s+(tb|gb|mb)(\s|$)',
      '\1\2 ',
      'g'
    ),
    ''
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1e_contains_identity_term(
  p_text text,
  p_term text
)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_text text;
  v_term text;
BEGIN
  IF p_text IS NULL OR p_term IS NULL THEN RETURN false; END IF;

  v_text:=retail.r1e_normalize_identity_phrase(p_text);
  v_term:=retail.r1e_normalize_identity_phrase(p_term);

  -- A bare capacity token can use unit-canonical equivalence (1TB=1000GB).
  IF v_term ~ '^[0-9]+(?:\.[0-9]+)?(tb|gb|mb)$' THEN
    RETURN retail.r1e_contains_canonical_attribute(
      p_text,'storage',p_term
    );
  END IF;

  -- Multi-token requirements preserve semantic context (e.g. "16GB RAM")
  -- rather than accepting any 16GB value found elsewhere in the title.
  RETURN (' '||v_text||' ') LIKE ('% '||v_term||' %');
END $$;

-- ---------- V2.1 VARIANT AUTHORITY ------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_variant_match_document_v21(
  p_target jsonb,
  p_returned jsonb,
  p_rules jsonb
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_target jsonb:=retail.r1e_target_variant_attributes(p_target);
  v_returned jsonb:=retail.r1e_returned_variant_attributes(p_returned);
  v_key text;
  v_expected_raw text;
  v_actual_raw text;
  v_expected text;
  v_actual text;
  v_hard_keys jsonb:=COALESCE(
    p_rules#>'{identity,hard_variant_keys}',
    '["normalized_model_token","generation","variant","storage","ram","platform"]'::jsonb
  );
  v_mismatches jsonb:='[]'::jsonb;
  v_missing jsonb:='[]'::jsonb;
  v_returned_text text:=concat_ws(
    ' ',
    p_returned->>'title',
    p_returned->>'model_number'
  );
BEGIN
  FOR v_key IN
    SELECT jsonb_array_elements_text(v_hard_keys)
  LOOP
    v_expected_raw:=NULLIF(v_target->>v_key,'');
    IF v_expected_raw IS NULL THEN CONTINUE; END IF;

    v_actual_raw:=NULLIF(v_returned->>v_key,'');
    v_expected:=retail.r1e_canonical_attribute_value(v_key,v_expected_raw);
    v_actual:=retail.r1e_canonical_attribute_value(v_key,v_actual_raw);

    IF v_actual IS NULL THEN
      IF NOT retail.r1e_contains_canonical_attribute(
        v_returned_text,v_key,v_expected_raw
      ) THEN
        v_missing:=v_missing||jsonb_build_array(
          jsonb_build_object(
            'attribute',v_key,
            'expected',v_expected,
            'raw_expected',v_expected_raw
          )
        );
      END IF;
    ELSIF v_actual<>v_expected THEN
      v_mismatches:=v_mismatches||jsonb_build_array(
        jsonb_build_object(
          'attribute',v_key,
          'expected',v_expected,
          'actual',v_actual,
          'raw_expected',v_expected_raw,
          'raw_actual',v_actual_raw
        )
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'target_attributes',v_target,
    'returned_attributes',v_returned,
    'hard_keys',v_hard_keys,
    'mismatches',v_mismatches,
    'missing_required',v_missing,
    'hard_match',
      jsonb_array_length(v_mismatches)=0
      AND jsonb_array_length(v_missing)=0
  );
END $$;

-- ---------- V2.1 MATCH ENGINE ------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_match_documents_v21(
  p_target jsonb,
  p_returned jsonb,
  p_rules jsonb,
  p_is_duplicate boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_base jsonb;
  v_variant jsonb;
  v_reasons jsonb;
  v_decision text;
  v_required_term text;
  v_missing_required jsonb:='[]'::jsonb;
  v_returned_text text:=concat_ws(
    ' ',
    p_returned->>'title',
    p_returned->>'model_number',
    p_returned#>>'{normalized_json,title}',
    p_returned#>>'{normalized_json,model}'
  );
BEGIN
  PERFORM retail.r1e_validate_ruleset_v2(p_rules);

  -- Start with V2 deterministic behavior, but never let V2 hard_include_terms
  -- reinterpret search expansion terms as exact identity constraints.
  v_base:=retail.r1e_match_documents_v2(
    jsonb_set(
      (
        p_target
        - 'include_terms'
        - 'normalized_identity'
        - 'required_identity_terms'
        - 'search_expansion_terms'
        - 'normalized_product_type'
        - 'normalized_model_token'
        - 'generation'
        - 'variant'
        - 'storage'
        - 'ram'
        - 'platform'
      ),
      '{allowed_product_conditions}',
      COALESCE(
        p_target->'allowed_product_conditions',
        p_target->'allowed_conditions',
        '[]'::jsonb
      ),
      true
    ),
    p_returned,
    jsonb_set(
      p_rules,
      '{identity,hard_include_terms}',
      'false'::jsonb,
      true
    ),
    false
  );

  v_variant:=retail.r1e_variant_match_document_v21(
    p_target,p_returned,p_rules
  );

  v_reasons:=COALESCE(v_base->'reason_codes','[]'::jsonb);
  v_decision:=v_base->>'decision';

  FOR v_required_term IN
    SELECT jsonb_array_elements_text(
      COALESCE(p_target->'required_identity_terms','[]'::jsonb)
    )
  LOOP
    IF NOT retail.r1e_contains_identity_term(
      v_returned_text,
      v_required_term
    ) THEN
      v_missing_required:=v_missing_required||
        jsonb_build_array(v_required_term);
    END IF;
  END LOOP;

  IF jsonb_array_length(v_missing_required)>0 THEN
    v_reasons:=v_reasons||
      jsonb_build_array('REQUIRED_IDENTITY_TERM_MISSING');
  END IF;

  IF COALESCE((v_variant->>'hard_match')::boolean,false) IS NOT TRUE THEN
    IF NOT (v_reasons ? 'VARIANT_MISMATCH') THEN
      v_reasons:=v_reasons||jsonb_build_array('VARIANT_MISMATCH');
    END IF;
    v_decision:='REJECTED_IDENTITY';
  ELSIF jsonb_array_length(v_missing_required)>0 THEN
    v_decision:='REJECTED_IDENTITY';
  END IF;

  IF p_is_duplicate AND v_decision='QUALIFIED' THEN
    v_decision:='REJECTED_DUPLICATE';
    v_reasons:=v_reasons||jsonb_build_array('DUPLICATE_OBSERVATION');
  END IF;

  RETURN v_base
    || jsonb_build_object(
      'decision',v_decision,
      'reason_codes',v_reasons,
      'variant_match',v_variant,
      'missing_required_identity_terms',v_missing_required
    );
END $$;

-- ---------- AMBIGUITY-SAFE LINEAGE ------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_resolve_attempt_for_capture(
  p_capture_id uuid
)
RETURNS bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  cap retail.raw_product_captures%ROWTYPE;
  v_attempt bigint;
  v_count integer;
BEGIN
  SELECT * INTO cap
  FROM retail.raw_product_captures
  WHERE id=p_capture_id;

  IF NOT FOUND OR cap.collection_run_id IS NULL THEN
    RAISE EXCEPTION 'R1E V2.1 capture missing or lacks collection_run_id';
  END IF;

  IF NOT EXISTS(
    SELECT 1
    FROM retail.collection_runs cr
    WHERE cr.id=cap.collection_run_id
      AND cr.platform_id=cap.platform_id
  ) THEN
    RAISE EXCEPTION
      'R1E V2.1 collection-run platform mismatch or collection run missing';
  END IF;

  SELECT count(*)::int,min(a.id)
  INTO v_count,v_attempt
  FROM retail.r1d_dispatch_attempts a
  JOIN retail.r1d_dispatch_jobs dj
    ON dj.id=a.job_id
   AND dj.status='succeeded'
  JOIN retail.search_job_compilations j
    ON j.id=dj.compilation_id
   AND j.platform_id=cap.platform_id
  WHERE a.success=true
    AND retail.r1e_try_uuid(
      a.metrics_json->>'collection_run_id'
    )=cap.collection_run_id;

  IF v_count=0 THEN
    RAISE EXCEPTION
      'R1E V2.1 lineage failed: no successful R1D attempt for collection run';
  ELSIF v_count<>1 THEN
    RAISE EXCEPTION
      'R1E V2.1 lineage contradiction: % successful R1D attempts claim collection run %',
      v_count,cap.collection_run_id;
  END IF;

  RETURN v_attempt;
END $$;

-- ---------- OBSERVATION IDENTITY V2.1 ---------------------------------------
-- raw_payload_hash remains forensic evidence but is deliberately excluded
-- from duplicate identity because volatile retailer payload fields must not
-- split economically identical observations.
CREATE OR REPLACE FUNCTION retail.r1e_observation_document_v21(
  p_capture retail.raw_product_captures,
  p_compilation retail.search_job_compilations,
  p_product retail.retail_products
)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_offer record;
  v_location jsonb;
BEGIN
  SELECT
    o.effective_price,
    o.currency_code,
    o.availability::text availability,
    o.quantity_available,
    o.shipping_cost_estimate,
    o.estimated_tax,
    o.estimated_total_cost
  INTO v_offer
  FROM retail.retail_offer_snapshots o
  WHERE o.raw_capture_id=p_capture.id
    AND o.platform_id=p_capture.platform_id
  ORDER BY o.captured_at DESC,o.id::text DESC
  LIMIT 1;

  v_location:=COALESCE(
    p_compilation.normalized_job_json->'location',
    '{}'::jsonb
  );

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'collection_run_id',p_capture.collection_run_id,
    'compilation_id',p_compilation.id,
    'location',v_location,
    'platform_id',p_capture.platform_id,
    'collection_source_id',p_capture.collection_source_id,
    'platform_product_key',p_capture.platform_product_key,
    'offer',jsonb_strip_nulls(jsonb_build_object(
      'effective_price',v_offer.effective_price,
      'currency_code',v_offer.currency_code,
      'availability',v_offer.availability,
      'quantity_available',v_offer.quantity_available,
      'shipping_cost_estimate',v_offer.shipping_cost_estimate,
      'estimated_tax',v_offer.estimated_tax,
      'estimated_total_cost',v_offer.estimated_total_cost
    ))
  ));
END $$;

-- ---------- CERTIFICATION-ONLY RESULT FLAG ----------------------------------
ALTER TABLE retail.r1e_qualification_results
  ADD COLUMN IF NOT EXISTS certification_fixture boolean NOT NULL DEFAULT false;

-- ---------- FULL V2.1 EVALUATOR ---------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_evaluate_capture_v21(
  p_raw_capture_id uuid,
  p_ruleset_id uuid,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text,
  p_certification_fixture boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
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
    'model_number',COALESCE(
      rp.model_number,
      rp.normalized_json->>'model',
      rp.normalized_json->>'model_number',
      cap.raw_payload->>'model',
      cap.raw_payload->>'model_number'
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
      'normalized_model_token',COALESCE(
        rp.normalized_json->>'normalized_model_token',
        rp.model_number
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
        retail.r1e_normalize_text(COALESCE(
          rp.model_number,
          rp.normalized_json->>'model',
          cap.raw_payload->>'model'
        ))
    ))
  );

  v_observation_doc:=retail.r1e_observation_document_v21(
    cap,comp,rp
  );
  v_observation_fp:=retail.r1e_sha256_jsonb(v_observation_doc);

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
      raw_capture_id,ruleset_id,r1d_certification_run_id
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
      raw_capture_id,ruleset_id,r1d_certification_run_id
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
      AND r1d_certification_run_id=bind.r1d_certification_run_id;
  END IF;

  RETURN v_id;
END $$;

-- ---------- E2E CERTIFICATION FIXTURE AUTHORITY ------------------------------
CREATE TABLE IF NOT EXISTS retail.r1e_e2e_qa_fixtures(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fixture_code text NOT NULL UNIQUE,
  raw_capture_id uuid NOT NULL
    REFERENCES retail.raw_product_captures(id) ON DELETE RESTRICT,
  ruleset_code text NOT NULL,
  fixture_class text NOT NULL CHECK(fixture_class IN(
    'positive_identity','wrong_brand','wrong_model','wrong_variant',
    'accessory','condition','incomplete','bundle_variant'
  )),
  expected_decision text NOT NULL CHECK(expected_decision IN(
    'QUALIFIED','REJECTED_IDENTITY','REJECTED_ACCESSORY',
    'REJECTED_CONDITION','REJECTED_INCOMPLETE'
  )),
  expected_reason_family text,
  sequence_no integer NOT NULL CHECK(sequence_no>0),
  fixture_sha256 text NOT NULL CHECK(fixture_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1e_e2e_fixture_document(
  p_row retail.r1e_e2e_qa_fixtures
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT
AS $$
  SELECT jsonb_build_object(
    'fixture_code',p_row.fixture_code,
    'raw_capture_id',p_row.raw_capture_id,
    'ruleset_code',p_row.ruleset_code,
    'fixture_class',p_row.fixture_class,
    'expected_decision',p_row.expected_decision,
    'expected_reason_family',p_row.expected_reason_family,
    'sequence_no',p_row.sequence_no
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1e_prepare_e2e_fixture()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.fixture_sha256:=retail.r1e_sha256_jsonb(
    retail.r1e_e2e_fixture_document(NEW)
  );
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1e_prepare_e2e_fixture
ON retail.r1e_e2e_qa_fixtures;
CREATE TRIGGER trg_r1e_prepare_e2e_fixture
BEFORE INSERT OR UPDATE ON retail.r1e_e2e_qa_fixtures
FOR EACH ROW EXECUTE FUNCTION retail.r1e_prepare_e2e_fixture();

CREATE OR REPLACE FUNCTION retail.r1e_e2e_fixture_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1E V2.1 E2E fixtures cannot be deleted';
  END IF;

  IF OLD.active=true THEN
    IF (to_jsonb(NEW)-ARRAY['active'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['active']) THEN
      RAISE EXCEPTION 'Active R1E V2.1 E2E fixture immutable';
    END IF;
  ELSIF NEW.active<>OLD.active THEN
    RAISE EXCEPTION 'Inactive R1E V2.1 E2E fixture cannot be reactivated';
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1e_e2e_fixture_guard
ON retail.r1e_e2e_qa_fixtures;
CREATE TRIGGER trg_r1e_e2e_fixture_guard
BEFORE UPDATE OR DELETE ON retail.r1e_e2e_qa_fixtures
FOR EACH ROW EXECUTE FUNCTION retail.r1e_e2e_fixture_guard();

CREATE TABLE IF NOT EXISTS retail.r1e_duplicate_race_fixtures(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fixture_code text NOT NULL UNIQUE,
  capture_a_id uuid NOT NULL
    REFERENCES retail.raw_product_captures(id) ON DELETE RESTRICT,
  capture_b_id uuid NOT NULL
    REFERENCES retail.raw_product_captures(id) ON DELETE RESTRICT,
  ruleset_code text NOT NULL,
  fixture_sha256 text NOT NULL CHECK(fixture_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(capture_a_id<>capture_b_id)
);

CREATE OR REPLACE FUNCTION retail.r1e_duplicate_race_fixture_document(
  p_row retail.r1e_duplicate_race_fixtures
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT
AS $$
  SELECT jsonb_build_object(
    'fixture_code',p_row.fixture_code,
    'capture_a_id',p_row.capture_a_id,
    'capture_b_id',p_row.capture_b_id,
    'ruleset_code',p_row.ruleset_code
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1e_prepare_duplicate_race_fixture()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.fixture_sha256:=retail.r1e_sha256_jsonb(
    retail.r1e_duplicate_race_fixture_document(NEW)
  );
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1e_prepare_duplicate_race_fixture
BEFORE INSERT OR UPDATE ON retail.r1e_duplicate_race_fixtures
FOR EACH ROW EXECUTE FUNCTION retail.r1e_prepare_duplicate_race_fixture();

CREATE OR REPLACE FUNCTION retail.r1e_duplicate_race_fixture_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1E V2.1 duplicate race fixtures cannot be deleted';
  END IF;

  IF OLD.active=true THEN
    IF (to_jsonb(NEW)-ARRAY['active'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['active']) THEN
      RAISE EXCEPTION 'Active R1E V2.1 duplicate race fixture immutable';
    END IF;
  ELSIF NEW.active<>OLD.active THEN
    RAISE EXCEPTION 'Inactive duplicate race fixture cannot be reactivated';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1e_duplicate_race_fixture_guard
BEFORE UPDATE OR DELETE ON retail.r1e_duplicate_race_fixtures
FOR EACH ROW EXECUTE FUNCTION retail.r1e_duplicate_race_fixture_guard();

CREATE TRIGGER trg_r1e_audit_e2e_fixtures
AFTER INSERT OR UPDATE OR DELETE ON retail.r1e_e2e_qa_fixtures
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1e_log_retail_change();

CREATE TRIGGER trg_r1e_audit_duplicate_race_fixtures
AFTER INSERT OR UPDATE OR DELETE ON retail.r1e_duplicate_race_fixtures
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1e_log_retail_change();

-- ---------- GREEN TIER 1 POLICY FLOOR ---------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_validate_cert_policy(p_policy jsonb)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_class text;
  v_required jsonb:='{
    "positive_identity":150,
    "wrong_brand":100,
    "wrong_model":150,
    "wrong_variant":200,
    "accessory":150,
    "condition":100,
    "duplicate":150,
    "incomplete":100,
    "bundle_variant":100
  }'::jsonb;
BEGIN
  IF p_policy IS NULL OR jsonb_typeof(p_policy)<>'object' THEN
    RAISE EXCEPTION 'R1E certification policy must be JSON object';
  END IF;

  IF COALESCE((p_policy->>'minimum_total_fixtures')::int,0)<1200
     OR COALESCE((p_policy->>'minimum_e2e_fixtures')::int,0)<100
     OR COALESCE((p_policy->>'minimum_e2e_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_decision_accuracy')::numeric,-1)<98
     OR COALESCE((p_policy->>'minimum_positive_precision')::numeric,-1)<98
     OR COALESCE((p_policy->>'minimum_positive_recall')::numeric,-1)<98
     OR COALESCE((p_policy->>'minimum_duplicate_accuracy')::numeric,-1)<99.9
     OR COALESCE((p_policy->>'maximum_false_positive_rate')::numeric,101)>5
     OR COALESCE((p_policy->>'maximum_wrong_variant_fpr')::numeric,101)>1
     OR COALESCE((p_policy->>'minimum_reason_family_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_evidence_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_replay_coverage')::numeric,-1)<100 THEN
    RAISE EXCEPTION 'R1E V2.1 policy weaker than GREEN TIER 1 floor';
  END IF;

  IF jsonb_typeof(COALESCE(p_policy->'class_minimums','{}'::jsonb))<>'object' THEN
    RAISE EXCEPTION 'class_minimums must be object';
  END IF;

  FOR v_class IN SELECT jsonb_object_keys(v_required)
  LOOP
    IF COALESCE(
      (p_policy#>>ARRAY['class_minimums',v_class])::int,0
    ) < (v_required->>v_class)::int THEN
      RAISE EXCEPTION
        'R1E V2.1 class % minimum below Green Tier 1 floor %',
        v_class,(v_required->>v_class)::int;
    END IF;
  END LOOP;
END $$;

-- ---------- CERTIFICATION RESULT EXTENSIONS ---------------------------------
ALTER TABLE retail.r1e_certification_runs
  ADD COLUMN IF NOT EXISTS e2e_results jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS e2e_fixture_manifest_sha256 text;


DROP TRIGGER IF EXISTS trg_r1e_audit_certification_policies
ON retail.r1e_certification_policies;
CREATE TRIGGER trg_r1e_audit_certification_policies
AFTER INSERT OR UPDATE OR DELETE ON retail.r1e_certification_policies
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1e_log_retail_change();

-- ---------- FINAL CURRENTNESS ------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_latest_certification_is_current(
  p_ruleset_id uuid
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      cr.certification_status='CERTIFIED'
      AND cr.certification_version='r1e-v2.1.0'
      AND cr.ruleset_id=p_ruleset_id
      AND cr.ruleset_sha256=rs.rules_sha256
      AND rs.certification_status='certified'
      AND rs.rules_sha256=retail.r1e_sha256_jsonb(rs.rules_json)
      AND retail.r1e_upstream_identity_is_current(
            cr.r1d_certification_run_id,
            cr.r1d_package_sha256
          )=true
      AND p.certification_status='certified'
      AND cr.certification_policy_id=p.id
      AND cr.certification_policy_sha256=p.policy_sha256
      AND p.policy_sha256=retail.r1e_sha256_jsonb(p.policy_json)
      AND cr.e2e_fixture_manifest_sha256 IS NOT NULL
      AND retail.r1e_r1d_binding_is_current()=true
    FROM retail.r1e_certification_runs cr
    JOIN retail.r1e_match_rulesets rs
      ON rs.id=cr.ruleset_id
    JOIN retail.r1e_certification_policies p
      ON p.id=cr.certification_policy_id
    WHERE cr.id=(
      SELECT x.id
      FROM retail.r1e_certification_runs x
      WHERE x.completed_at IS NOT NULL
      ORDER BY x.completed_at DESC,x.id::text DESC
      LIMIT 1
    )
  ),false)
$$;

CREATE OR REPLACE FUNCTION retail.r1e_result_is_current(
  p_result_id uuid
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      q.engine_version='r1e-v2.1.0'
      AND q.certification_fixture=false
      AND retail.r1e_upstream_identity_is_current(
            q.r1d_certification_run_id,
            q.r1d_package_sha256
          )=true
      AND q.ruleset_sha256=rs.rules_sha256
      AND q.evidence_sha256=retail.r1e_sha256_jsonb(q.evidence_json)
      AND q.r1d_attempt_evidence_sha256=
          retail.r1e_sha256_jsonb(q.r1d_attempt_evidence_json)
      AND q.r1c_compilation_key=j.compilation_key
      AND q.route_authority_hash=j.route_authority_hash
      AND q.r1a_revision_id=j.r1a_revision_id
      AND q.r1a_revision_hash=j.r1a_revision_hash
      AND EXISTS(
        SELECT 1
        FROM retail.search_target_revisions r
        WHERE r.id=q.r1a_revision_id
          AND r.revision_hash=q.r1a_revision_hash
          AND r.revision_hash=retail.r1a_sha256_jsonb(
            retail.r1a_revision_business_document(r)
          )
      )
      AND retail.r1e_latest_certification_is_current(q.ruleset_id)=true
    FROM retail.r1e_qualification_results q
    JOIN retail.r1e_match_rulesets rs
      ON rs.id=q.ruleset_id
    JOIN retail.search_job_compilations j
      ON j.id=q.compilation_id
    WHERE q.id=p_result_id
  ),false)
$$;

CREATE OR REPLACE VIEW retail.r1e_effective_qualified_products AS
SELECT
  q.id,
  q.raw_capture_id,
  q.retail_product_id,
  q.platform_id,
  q.compilation_id,
  q.route_id,
  q.target_id,
  q.ruleset_id,
  q.r1d_certification_run_id,
  q.r1d_package_sha256,
  q.r1c_compilation_key,
  q.route_authority_hash,
  q.r1a_revision_id,
  q.r1a_revision_hash,
  q.ruleset_sha256,
  q.engine_version,
  q.returned_identity_json,
  q.target_identity_json,
  q.identity_score,
  q.accessory_score,
  q.condition_score,
  q.confidence_score,
  q.product_identity_fingerprint,
  q.observation_fingerprint,
  q.observation_context_json,
  q.reason_codes,
  q.evidence_json,
  q.evidence_sha256,
  q.qualified_at
FROM retail.r1e_qualification_results q
WHERE q.decision='QUALIFIED'
  AND q.certification_fixture=false
  AND retail.r1e_result_is_current(q.id)=true;

-- Safe intake exposes only unambiguous platform-consistent lineages.
CREATE OR REPLACE VIEW retail.r1e_pending_captures AS
WITH lineage AS (
  SELECT
    c.id raw_capture_id,
    count(a.id)::int matching_attempts,
    min(a.id) attempt_id
  FROM retail.raw_product_captures c
  JOIN retail.collection_runs cr
    ON cr.id=c.collection_run_id
   AND cr.platform_id=c.platform_id
  JOIN retail.r1d_dispatch_attempts a
    ON a.success=true
   AND retail.r1e_try_uuid(
         a.metrics_json->>'collection_run_id'
       )=c.collection_run_id
  JOIN retail.r1d_dispatch_jobs dj
    ON dj.id=a.job_id
   AND dj.status='succeeded'
  JOIN retail.search_job_compilations j
    ON j.id=dj.compilation_id
   AND j.platform_id=c.platform_id
  WHERE c.collection_run_id IS NOT NULL
  GROUP BY c.id
  HAVING count(a.id)=1
)
SELECT
  c.id raw_capture_id,
  c.platform_id,
  c.collection_run_id,
  c.platform_product_key,
  c.captured_at,
  a.id r1d_attempt_id,
  a.job_id r1d_job_id,
  j.id compilation_id,
  j.route_id,
  j.target_id
FROM lineage l
JOIN retail.raw_product_captures c
  ON c.id=l.raw_capture_id
JOIN retail.r1d_dispatch_attempts a
  ON a.id=l.attempt_id
JOIN retail.r1d_dispatch_jobs dj
  ON dj.id=a.job_id
JOIN retail.search_job_compilations j
  ON j.id=dj.compilation_id
WHERE retail.r1e_r1d_binding_is_current()=true;

CREATE OR REPLACE VIEW retail.r1e_lineage_anomalies AS
SELECT
  c.id raw_capture_id,
  c.collection_run_id,
  c.platform_id,
  CASE
    WHEN c.collection_run_id IS NULL THEN 'MISSING_COLLECTION_RUN'
    WHEN cr.id IS NULL THEN 'COLLECTION_RUN_MISSING_OR_PLATFORM_MISMATCH'
    WHEN count(a.id)=0 THEN 'NO_SUCCESSFUL_R1D_ATTEMPT'
    WHEN count(a.id)>1 THEN 'AMBIGUOUS_R1D_ATTEMPT'
    ELSE NULL
  END anomaly_code,
  count(a.id)::int matching_attempts
FROM retail.raw_product_captures c
LEFT JOIN retail.collection_runs cr
  ON cr.id=c.collection_run_id
 AND cr.platform_id=c.platform_id
LEFT JOIN retail.r1d_dispatch_attempts a
  ON a.success=true
 AND retail.r1e_try_uuid(
       a.metrics_json->>'collection_run_id'
     )=c.collection_run_id
LEFT JOIN retail.r1d_dispatch_jobs dj
  ON dj.id=a.job_id
 AND dj.status='succeeded'
LEFT JOIN retail.search_job_compilations j
  ON j.id=dj.compilation_id
 AND j.platform_id=c.platform_id
GROUP BY c.id,c.collection_run_id,c.platform_id,cr.id
HAVING
  c.collection_run_id IS NULL
  OR cr.id IS NULL
  OR count(a.id)<>1;


CREATE OR REPLACE FUNCTION retail.r1e_v21_certification_insert_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.certification_version='r1e-v2.1.0' THEN
    IF NEW.certification_policy_id IS NULL
       OR NEW.certification_policy_sha256 IS NULL
       OR NEW.e2e_fixture_manifest_sha256 IS NULL
       OR NEW.e2e_fixture_manifest_sha256 !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION
        'R1E V2.1 certification requires immutable policy and E2E fixture manifest';
    END IF;

    IF NOT EXISTS(
      SELECT 1
      FROM retail.r1e_certification_policies p
      WHERE p.id=NEW.certification_policy_id
        AND p.certification_status='certified'
        AND p.policy_sha256=NEW.certification_policy_sha256
        AND p.policy_sha256=retail.r1e_sha256_jsonb(p.policy_json)
    ) THEN
      RAISE EXCEPTION 'R1E V2.1 certification policy identity invalid';
    END IF;

    IF NEW.e2e_results IS NULL
       OR jsonb_typeof(NEW.e2e_results)<>'object'
       OR COALESCE((NEW.e2e_results->>'allPassed')::boolean,false) IS NOT TRUE THEN
      RAISE EXCEPTION 'R1E V2.1 E2E certification must pass';
    END IF;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1e_v21_certification_insert_guard
ON retail.r1e_certification_runs;
CREATE TRIGGER trg_r1e_v21_certification_insert_guard
BEFORE INSERT ON retail.r1e_certification_runs
FOR EACH ROW EXECUTE FUNCTION retail.r1e_v21_certification_insert_guard();

-- ---------- PRIVILEGES -------------------------------------------------------
REVOKE ALL ON FUNCTION retail.r1e_r1a_revision_identity_document(uuid,text)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_resolve_attempt_for_capture(uuid)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_evaluate_capture_v21(uuid,uuid,uuid,text,text,boolean)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION retail.r1e_evaluate_capture_v21(uuid,uuid,uuid,text,text,boolean)
  TO retail_r1e_worker,retail_r1e_certifier;

GRANT SELECT ON retail.r1e_lineage_anomalies TO retail_r1e_reader;

COMMIT;
