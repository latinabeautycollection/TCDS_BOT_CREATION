BEGIN;

-- ============================================================================
-- TCDS RETAIL R1E V2
-- EXACT PRODUCT IDENTITY & OBSERVATION QUALIFICATION — GREEN TIER 1 FINAL
-- Additive hardening over 038_r1e_product_match_qualification.sql
-- ============================================================================

DO $$
DECLARE
  v_latest record;
BEGIN
  IF to_regclass('retail.r1e_schema_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1e_schema_state
       WHERE singleton=true AND schema_version='1.0.0'
     ) THEN
    RAISE EXCEPTION 'R1E V2 requires installed R1E V1 schema 1.0.0';
  END IF;

  IF to_regclass('retail.r1d_v2_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1d_v2_state
       WHERE singleton=true AND hardening_version='2.0.0'
     ) THEN
    RAISE EXCEPTION 'R1E V2 requires R1D hardening 2.0.0';
  END IF;

  SELECT * INTO v_latest
  FROM retail.r1d_certification_runs
  WHERE completed_at IS NOT NULL
  ORDER BY completed_at DESC,id::text DESC
  LIMIT 1;

  IF NOT FOUND
     OR v_latest.certification_status<>'CERTIFIED'
     OR v_latest.certification_version<>'r1d-v2.0.0' THEN
    RAISE EXCEPTION 'R1E V2 requires latest R1D certification = r1d-v2.0.0 CERTIFIED';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS retail.r1e_v2_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  hardening_version text NOT NULL,
  doctrine text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user
);

INSERT INTO retail.r1e_v2_state(singleton,hardening_version,doctrine)
VALUES(
  true,'2.0.0',
  'R1E V2 distinguishes product identity from observation identity, binds every result/certification to exact R1D authority, evaluates immutable R1C snapshots, enforces hard variant identity, seals R1D attempt evidence, and certifies under immutable versioned policy.'
)
ON CONFLICT(singleton) DO UPDATE SET
  hardening_version=EXCLUDED.hardening_version,
  doctrine=EXCLUDED.doctrine;

-- ---------- PROCESS REGISTRY -------------------------------------------------
INSERT INTO arb.process_registry(
  process_name,phase_no,process_group,description,owner_team,active_flag
)
VALUES
('RETAIL_R1E_V2_POLICY_REGISTER',2,'RETAIL_AUTOMATION',
 'Register immutable versioned R1E certification policy.',
 'TCDS Retail Automation',true),
('RETAIL_R1E_V2_DUPLICATE_CONCURRENCY_TEST',2,'RETAIL_AUTOMATION',
 'Exercise production observation-lock duplicate serialization.',
 'TCDS Retail Automation',true)
ON CONFLICT(process_name) DO NOTHING;

-- ---------- SAFE PARSING / PROCESS AUTHORITY --------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_try_uuid(p_text text)
RETURNS uuid
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
  IF p_text IS NULL
     OR p_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
    RETURN NULL;
  END IF;
  RETURN p_text::uuid;
EXCEPTION WHEN invalid_text_representation THEN
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION retail.r1e_assert_process_run(
  p_run_id uuid,
  p_allowed_processes text[]
)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,arb
AS $$
DECLARE
  r record;
BEGIN
  SELECT process_name,status,correlation_id
  INTO r
  FROM arb.process_runs
  WHERE run_id=p_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1E process run does not exist';
  END IF;

  IF NOT (r.process_name=ANY(p_allowed_processes)) THEN
    RAISE EXCEPTION
      'R1E process run family % not allowed for this authority',
      r.process_name;
  END IF;

  IF r.status<>'STARTED' THEN
    RAISE EXCEPTION 'R1E authority requires STARTED process run, got %',r.status;
  END IF;
END $$;


CREATE OR REPLACE FUNCTION retail.r1e_bind_r1d_certification_v2(
  p_r1d_certification_run_id uuid,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  cr record;
  v_latest uuid;
BEGIN
  PERFORM retail.r1e_assert_process_run(
    p_process_run_id,
    ARRAY['RETAIL_R1E_R1D_BIND']
  );

  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  SELECT id INTO v_latest
  FROM retail.r1d_certification_runs
  WHERE completed_at IS NOT NULL
  ORDER BY completed_at DESC,id::text DESC
  LIMIT 1;

  IF v_latest IS DISTINCT FROM p_r1d_certification_run_id THEN
    RAISE EXCEPTION 'R1E V2 bind blocked: supplied R1D certification is not latest';
  END IF;

  SELECT * INTO cr
  FROM retail.r1d_certification_runs
  WHERE id=p_r1d_certification_run_id
    AND certification_status='CERTIFIED'
    AND certification_version='r1d-v2.0.0';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1E V2 bind requires latest R1D V2 CERTIFIED run';
  END IF;

  INSERT INTO retail.r1e_r1d_binding_history(
    r1d_certification_run_id,r1d_package_sha256,
    r1d_evidence_manifest_sha256,bound_by,
    source_process_run_id,source_correlation_id
  )
  VALUES(
    cr.id,cr.r1d_package_sha256,cr.evidence_manifest_sha256,
    p_actor,p_process_run_id,p_correlation_id
  );

  INSERT INTO retail.r1e_r1d_certification_binding(
    singleton,r1d_certification_run_id,r1d_certification_version,
    r1d_package_sha256,r1d_evidence_manifest_sha256,
    bound_by,bound_at,source_process_run_id,source_correlation_id,updated_at
  )
  VALUES(
    true,cr.id,'r1d-v2.0.0',
    cr.r1d_package_sha256,cr.evidence_manifest_sha256,
    p_actor,now(),p_process_run_id,p_correlation_id,now()
  )
  ON CONFLICT(singleton) DO UPDATE SET
    r1d_certification_run_id=EXCLUDED.r1d_certification_run_id,
    r1d_certification_version=EXCLUDED.r1d_certification_version,
    r1d_package_sha256=EXCLUDED.r1d_package_sha256,
    r1d_evidence_manifest_sha256=EXCLUDED.r1d_evidence_manifest_sha256,
    bound_by=EXCLUDED.bound_by,
    bound_at=EXCLUDED.bound_at,
    source_process_run_id=EXCLUDED.source_process_run_id,
    source_correlation_id=EXCLUDED.source_correlation_id,
    updated_at=now();
END $$;

-- ---------- RULESET PROVENANCE ----------------------------------------------
ALTER TABLE retail.r1e_match_rulesets
  ADD COLUMN IF NOT EXISTS certification_process_run_id uuid
    REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS certification_correlation_id text;

CREATE OR REPLACE FUNCTION retail.r1e_certify_ruleset_v2(
  p_ruleset_id uuid,
  p_qa_evidence jsonb,
  p_process_run_id uuid,
  p_correlation_id text,
  p_certifier text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  r retail.r1e_match_rulesets%ROWTYPE;
BEGIN
  PERFORM retail.r1e_assert_process_run(
    p_process_run_id,
    ARRAY['RETAIL_R1E_RULESET_CERTIFY']
  );

  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id',p_certifier,true);
  PERFORM set_config('app.actor_name',p_certifier,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  PERFORM pg_advisory_xact_lock(
    hashtextextended('r1e-ruleset:'||p_ruleset_id::text,0)
  );

  SELECT * INTO r
  FROM retail.r1e_match_rulesets
  WHERE id=p_ruleset_id
  FOR UPDATE;

  IF NOT FOUND OR r.certification_status<>'draft' THEN
    RAISE EXCEPTION 'R1E V2 ruleset missing/not eligible';
  END IF;

  PERFORM retail.r1e_validate_ruleset(r.rules_json);

  IF p_qa_evidence IS NULL
     OR jsonb_typeof(p_qa_evidence)<>'object'
     OR p_qa_evidence='{}'::jsonb THEN
    RAISE EXCEPTION 'R1E V2 ruleset certification requires non-empty QA evidence';
  END IF;

  UPDATE retail.r1e_match_rulesets
  SET certification_status='suspended'
  WHERE ruleset_code=r.ruleset_code
    AND id<>r.id
    AND certification_status='certified';

  UPDATE retail.r1e_match_rulesets
  SET qa_evidence_json=p_qa_evidence,
      certification_status='certified',
      certification_process_run_id=p_process_run_id,
      certification_correlation_id=p_correlation_id,
      certified_by=p_certifier,
      certified_at=now()
  WHERE id=r.id;
END $$;


ALTER TABLE retail.r1e_qa_fixtures
  DROP CONSTRAINT IF EXISTS r1e_qa_fixtures_fixture_class_check;

ALTER TABLE retail.r1e_qa_fixtures
  ADD CONSTRAINT r1e_qa_fixtures_fixture_class_check
  CHECK(fixture_class IN(
    'positive_identity','wrong_brand','wrong_model','wrong_variant',
    'accessory','condition','duplicate','incomplete','bundle_variant'
  ));

-- ---------- VERSIONED CERTIFICATION POLICY ----------------------------------
CREATE TABLE retail.r1e_certification_policies(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_code text NOT NULL,
  policy_version text NOT NULL,
  policy_json jsonb NOT NULL CHECK(jsonb_typeof(policy_json)='object'),
  policy_sha256 text NOT NULL CHECK(policy_sha256 ~ '^[0-9a-f]{64}$'),
  certification_status text NOT NULL DEFAULT 'draft'
    CHECK(certification_status IN('draft','certified','suspended','retired')),
  created_by text NOT NULL,
  certified_by text,
  certification_process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  certification_correlation_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  certified_at timestamptz,
  UNIQUE(policy_code,policy_version)
);

CREATE UNIQUE INDEX uq_r1e_v2_one_certified_policy
ON retail.r1e_certification_policies(policy_code)
WHERE certification_status='certified';

CREATE OR REPLACE FUNCTION retail.r1e_prepare_cert_policy()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.policy_sha256:=retail.r1e_sha256_jsonb(NEW.policy_json);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1e_prepare_cert_policy
BEFORE INSERT OR UPDATE ON retail.r1e_certification_policies
FOR EACH ROW EXECUTE FUNCTION retail.r1e_prepare_cert_policy();

CREATE OR REPLACE FUNCTION retail.r1e_cert_policy_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1E certification policies cannot be deleted';
  END IF;

  IF OLD.certification_status='certified' THEN
    IF (to_jsonb(NEW)-ARRAY['certification_status'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['certification_status']) THEN
      RAISE EXCEPTION 'Certified R1E policy immutable; create new version';
    END IF;
    IF NEW.certification_status NOT IN('certified','suspended','retired') THEN
      RAISE EXCEPTION 'Invalid R1E certification policy transition';
    END IF;
  END IF;

  IF OLD.certification_status IN('suspended','retired')
     AND NEW.certification_status<>OLD.certification_status
     AND NOT (
       OLD.certification_status='suspended'
       AND NEW.certification_status='retired'
     ) THEN
    RAISE EXCEPTION 'Suspended/retired R1E policy cannot be reactivated';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1e_cert_policy_guard
BEFORE UPDATE OR DELETE ON retail.r1e_certification_policies
FOR EACH ROW EXECUTE FUNCTION retail.r1e_cert_policy_guard();

CREATE OR REPLACE FUNCTION retail.r1e_validate_cert_policy(p_policy jsonb)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_class text;
  v_required_classes constant text[]:=ARRAY[
    'positive_identity','wrong_brand','wrong_model','wrong_variant',
    'accessory','condition','duplicate','incomplete','bundle_variant'
  ];
BEGIN
  IF p_policy IS NULL OR jsonb_typeof(p_policy)<>'object' THEN
    RAISE EXCEPTION 'R1E certification policy must be JSON object';
  END IF;

  IF COALESCE((p_policy->>'minimum_total_fixtures')::int,0)<500 THEN
    RAISE EXCEPTION 'minimum_total_fixtures must be >= 500';
  END IF;

  IF COALESCE((p_policy->>'minimum_decision_accuracy')::numeric,-1)<98
     OR COALESCE((p_policy->>'minimum_positive_precision')::numeric,-1)<95
     OR COALESCE((p_policy->>'minimum_positive_recall')::numeric,-1)<95
     OR COALESCE((p_policy->>'minimum_duplicate_accuracy')::numeric,-1)<99.9
     OR COALESCE((p_policy->>'maximum_false_positive_rate')::numeric,101)>5
     OR COALESCE((p_policy->>'maximum_wrong_variant_fpr')::numeric,101)>2
     OR COALESCE((p_policy->>'minimum_reason_family_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_evidence_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_replay_coverage')::numeric,-1)<100 THEN
    RAISE EXCEPTION 'R1E certification policy weaker than Green Tier 1 floor';
  END IF;

  IF jsonb_typeof(COALESCE(p_policy->'class_minimums','{}'::jsonb))<>'object' THEN
    RAISE EXCEPTION 'class_minimums must be JSON object';
  END IF;

  FOREACH v_class IN ARRAY v_required_classes
  LOOP
    IF COALESCE((p_policy#>>ARRAY['class_minimums',v_class])::int,0)<50 THEN
      RAISE EXCEPTION
        'R1E certification class % requires at least 50 fixtures',
        v_class;
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION retail.r1e_certify_policy(
  p_policy_id uuid,
  p_process_run_id uuid,
  p_correlation_id text,
  p_certifier text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  p retail.r1e_certification_policies%ROWTYPE;
BEGIN
  PERFORM retail.r1e_assert_process_run(
    p_process_run_id,
    ARRAY['RETAIL_R1E_V2_POLICY_REGISTER']
  );

  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id',p_certifier,true);
  PERFORM set_config('app.actor_name',p_certifier,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  SELECT * INTO p
  FROM retail.r1e_certification_policies
  WHERE id=p_policy_id
  FOR UPDATE;

  IF NOT FOUND OR p.certification_status<>'draft' THEN
    RAISE EXCEPTION 'R1E certification policy missing/not eligible';
  END IF;

  PERFORM retail.r1e_validate_cert_policy(p.policy_json);

  UPDATE retail.r1e_certification_policies
  SET certification_status='suspended'
  WHERE policy_code=p.policy_code
    AND id<>p.id
    AND certification_status='certified';

  UPDATE retail.r1e_certification_policies
  SET certification_status='certified',
      certification_process_run_id=p_process_run_id,
      certification_correlation_id=p_correlation_id,
      certified_by=p_certifier,
      certified_at=now()
  WHERE id=p.id;
END $$;

-- ---------- OBSERVATION IDENTITY / CONCURRENCY -------------------------------
ALTER TABLE retail.r1e_qualification_results
  ADD COLUMN IF NOT EXISTS r1d_certification_run_id uuid
    REFERENCES retail.r1d_certification_runs(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS r1d_package_sha256 text,
  ADD COLUMN IF NOT EXISTS r1c_compilation_key text,
  ADD COLUMN IF NOT EXISTS route_authority_hash text,
  ADD COLUMN IF NOT EXISTS r1a_revision_id uuid,
  ADD COLUMN IF NOT EXISTS r1a_revision_hash text,
  ADD COLUMN IF NOT EXISTS ruleset_sha256 text,
  ADD COLUMN IF NOT EXISTS engine_version text,
  ADD COLUMN IF NOT EXISTS product_identity_fingerprint text,
  ADD COLUMN IF NOT EXISTS observation_fingerprint text,
  ADD COLUMN IF NOT EXISTS observation_context_json jsonb,
  ADD COLUMN IF NOT EXISTS r1d_attempt_evidence_json jsonb,
  ADD COLUMN IF NOT EXISTS r1d_attempt_evidence_sha256 text;

ALTER TABLE retail.r1e_qualification_results
  DROP CONSTRAINT IF EXISTS r1e_qualification_results_raw_capture_id_ruleset_id_key;

CREATE UNIQUE INDEX IF NOT EXISTS uq_r1e_v2_capture_ruleset_upstream
ON retail.r1e_qualification_results(
  raw_capture_id,ruleset_id,r1d_certification_run_id
)
WHERE r1d_certification_run_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_r1e_v2_one_qualified_observation
ON retail.r1e_qualification_results(
  ruleset_id,r1d_certification_run_id,observation_fingerprint
)
WHERE decision='QUALIFIED'
  AND observation_fingerprint IS NOT NULL
  AND r1d_certification_run_id IS NOT NULL;

CREATE OR REPLACE FUNCTION retail.r1e_observation_lock_key(
  p_fingerprint text
)
RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT
AS $$
  SELECT hashtextextended('r1e-observation:'||p_fingerprint,0)
$$;

CREATE OR REPLACE FUNCTION retail.r1e_try_observation_lock(
  p_fingerprint text
)
RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT pg_try_advisory_xact_lock(
    retail.r1e_observation_lock_key(p_fingerprint)
  )
$$;

-- ---------- SEALED R1D ATTEMPT EVIDENCE ------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_attempt_evidence_document(
  p_attempt_id bigint
)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'attempt_id',a.id,
    'job_id',a.job_id,
    'attempt_no',a.attempt_no,
    'worker_id',a.worker_id,
    'lease_token',a.lease_token,
    'started_at',a.started_at,
    'completed_at',a.completed_at,
    'success',a.success,
    'exit_code',a.exit_code,
    'error_code',a.error_code,
    'stdout_sha256',a.stdout_sha256,
    'stderr_sha256',a.stderr_sha256,
    'metrics_json',a.metrics_json,
    'actual_cost_usd',a.actual_cost_usd,
    'cost_basis',a.cost_basis,
    'process_run_id',a.process_run_id,
    'correlation_id',a.correlation_id
  ))
  FROM retail.r1d_dispatch_attempts a
  WHERE a.id=p_attempt_id
$$;

-- ---------- TOKEN / PHRASE AWARE MATCHING ----------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_contains_phrase(
  p_haystack text,
  p_phrase text
)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN retail.r1e_normalize_text(p_haystack) IS NULL
      OR retail.r1e_normalize_text(p_phrase) IS NULL
    THEN false
    ELSE
      (' '||retail.r1e_normalize_text(p_haystack)||' ')
      LIKE
      ('% '||retail.r1e_normalize_text(p_phrase)||' %')
  END
$$;

-- ---------- IMMUTABLE COMPILATION TARGET SNAPSHOT ---------------------------
CREATE OR REPLACE FUNCTION retail.r1e_compilation_target_document(
  p_compilation_id uuid
)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT jsonb_strip_nulls(
    COALESCE(j.normalized_job_json->'target','{}'::jsonb)
    || jsonb_build_object(
      'r1c_compilation_id',j.id,
      'r1c_compilation_key',j.compilation_key,
      'route_id',j.route_id,
      'route_authority_hash',j.route_authority_hash,
      'r1a_revision_id',j.r1a_revision_id,
      'r1a_revision_hash',j.r1a_revision_hash,
      'platform_id',j.platform_id,
      'location',j.normalized_job_json->'location'
    )
  )
  FROM retail.search_job_compilations j
  WHERE j.id=p_compilation_id
$$;

-- ---------- NORMALIZED HARD VARIANT ATTRIBUTES -------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_target_variant_attributes(
  p_target jsonb
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_strip_nulls(
    COALESCE(p_target->'normalized_identity','{}'::jsonb)
    || jsonb_build_object(
      'normalized_product_type',
        COALESCE(
          p_target->>'normalized_product_type',
          p_target#>>'{normalized_identity,normalized_product_type}'
        ),
      'normalized_model_token',
        COALESCE(
          p_target->>'normalized_model_token',
          p_target#>>'{normalized_identity,normalized_model_token}'
        ),
      'generation',
        COALESCE(
          p_target->>'generation',
          p_target#>>'{normalized_identity,generation}'
        ),
      'variant',
        COALESCE(
          p_target->>'variant',
          p_target#>>'{normalized_identity,variant}'
        ),
      'storage',
        COALESCE(
          p_target->>'storage',
          p_target#>>'{normalized_identity,storage}'
        ),
      'ram',
        COALESCE(
          p_target->>'ram',
          p_target#>>'{normalized_identity,ram}'
        ),
      'platform',
        COALESCE(
          p_target->>'platform',
          p_target#>>'{normalized_identity,platform}'
        ),
      'canonical_product_key',p_target->>'canonical_product_key'
    )
  )
$$;

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
          p_returned#>>'{normalized_json,generation}'
        ),
      'variant',
        COALESCE(
          p_returned->>'variant',
          p_returned#>>'{normalized_json,variant}'
        ),
      'storage',
        COALESCE(
          p_returned->>'storage',
          p_returned#>>'{normalized_json,storage}'
        ),
      'ram',
        COALESCE(
          p_returned->>'ram',
          p_returned#>>'{normalized_json,ram}'
        ),
      'platform',
        COALESCE(
          p_returned->>'platform',
          p_returned#>>'{normalized_json,platform}'
        )
    )
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1e_variant_match_document(
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
  v_expected text;
  v_actual text;
  v_hard_keys jsonb:=COALESCE(
    p_rules#>'{identity,hard_variant_keys}',
    '["normalized_model_token","generation","variant","storage","ram","platform"]'::jsonb
  );
  v_mismatches jsonb:='[]'::jsonb;
  v_missing jsonb:='[]'::jsonb;
BEGIN
  FOR v_key IN
    SELECT jsonb_array_elements_text(v_hard_keys)
  LOOP
    v_expected:=NULLIF(v_target->>v_key,'');
    IF v_expected IS NULL THEN
      CONTINUE;
    END IF;

    v_actual:=NULLIF(v_returned->>v_key,'');

    IF v_actual IS NULL THEN
      -- Returned structured field may be absent; exact phrase in title/model
      -- remains acceptable evidence when it contains the expected attribute.
      IF NOT (
        retail.r1e_contains_phrase(
          concat_ws(' ',p_returned->>'title',p_returned->>'model_number'),
          v_expected
        )
      ) THEN
        v_missing:=v_missing||jsonb_build_array(v_key);
      END IF;
    ELSIF retail.r1e_normalize_text(v_actual)
          <>retail.r1e_normalize_text(v_expected) THEN
      v_mismatches:=v_mismatches||jsonb_build_array(
        jsonb_build_object(
          'attribute',v_key,
          'expected',v_expected,
          'actual',v_actual
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

-- ---------- IDENTIFIER MATCHING ---------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_identifier_match_document(
  p_target jsonb,
  p_returned jsonb
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_expected jsonb:=COALESCE(
    p_target->'identifiers',
    p_target->'expected_identifiers',
    '{}'::jsonb
  );
  v_key text;
  v_expected_value text;
  v_actual text;
  v_expected_count integer:=0;
  v_matches integer:=0;
  v_mismatches jsonb:='[]'::jsonb;
BEGIN
  FOREACH v_key IN ARRAY ARRAY['upc','ean','asin','sku']
  LOOP
    v_expected_value:=NULLIF(v_expected->>v_key,'');
    IF v_expected_value IS NULL THEN
      CONTINUE;
    END IF;

    v_expected_count:=v_expected_count+1;
    v_actual:=NULLIF(p_returned->>v_key,'');

    IF v_actual IS NOT NULL
       AND retail.r1e_normalize_text(v_actual)=
           retail.r1e_normalize_text(v_expected_value) THEN
      v_matches:=v_matches+1;
    ELSE
      v_mismatches:=v_mismatches||jsonb_build_array(
        jsonb_build_object(
          'identifier',v_key,
          'expected',v_expected_value,
          'actual',v_actual
        )
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'expected_count',v_expected_count,
    'matches',v_matches,
    'mismatches',v_mismatches,
    'score',CASE
      WHEN v_expected_count=0 THEN 0
      ELSE round(100.0*v_matches/v_expected_count,4)
    END,
    'hard_match',jsonb_array_length(v_mismatches)=0
  );
END $$;

-- ---------- RULESET V2 VALIDATION -------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_validate_ruleset_v2(p_rules jsonb)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_confidence_algorithm text;
  v_duplicate_scope text;
  v_condition_strategy text;
BEGIN
  PERFORM retail.r1e_validate_ruleset(p_rules);

  v_confidence_algorithm:=p_rules#>>'{confidence,algorithm}';
  v_duplicate_scope:=p_rules#>>'{duplicate,scope}';
  v_condition_strategy:=p_rules#>>'{condition,strategy}';

  IF v_confidence_algorithm<>'weighted_identity_penalized' THEN
    RAISE EXCEPTION
      'R1E V2 confidence.algorithm must be weighted_identity_penalized';
  END IF;

  IF v_duplicate_scope<>'execution_observation' THEN
    RAISE EXCEPTION
      'R1E V2 duplicate.scope must be execution_observation';
  END IF;

  IF v_condition_strategy<>'r1a_allowed_conditions' THEN
    RAISE EXCEPTION
      'R1E V2 condition.strategy must be r1a_allowed_conditions';
  END IF;

  IF jsonb_typeof(
    COALESCE(
      p_rules#>'{identity,hard_variant_keys}',
      '[]'::jsonb
    )
  )<>'array' THEN
    RAISE EXCEPTION 'identity.hard_variant_keys must be array';
  END IF;
END $$;

-- ---------- V2 MATCH ENGINE --------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_match_documents_v2(
  p_target jsonb,
  p_returned jsonb,
  p_rules jsonb,
  p_is_duplicate boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_target_title text;
  v_title text:=p_returned->>'title';
  v_brand text:=p_returned->>'brand';
  v_model text:=p_returned->>'model_number';
  v_condition text:=p_returned->>'condition';

  v_title_score numeric:=0;
  v_brand_score numeric:=0;
  v_model_score numeric:=0;
  v_identifier_score numeric:=0;
  v_identity numeric:=0;
  v_accessory numeric:=0;
  v_condition_score numeric:=100;
  v_confidence numeric:=0;

  v_brand_weight numeric;
  v_model_weight numeric;
  v_title_weight numeric;
  v_identifier_weight numeric;
  v_weight_denominator numeric:=0;
  v_identity_min numeric;
  v_min_model_score numeric;
  v_min_title_score numeric;
  v_require_brand boolean;
  v_accessory_threshold numeric;
  v_bundle_reject boolean;

  v_variant jsonb;
  v_identifier jsonb;
  v_decision text;
  v_reasons jsonb:='[]'::jsonb;
  v_term text;
  v_allowed text;
  v_missing_required_terms jsonb:='[]'::jsonb;
  v_hard_include_terms boolean;
BEGIN
  PERFORM retail.r1e_validate_ruleset_v2(p_rules);

  IF jsonb_typeof(p_target)<>'object'
     OR jsonb_typeof(p_returned)<>'object' THEN
    RAISE EXCEPTION 'R1E V2 match documents must be objects';
  END IF;

  IF NULLIF(p_target->>'brand','') IS NULL
     AND NULLIF(p_target->>'model_family','') IS NULL
     AND NULLIF(p_target->>'canonical_product_key','') IS NULL THEN
    RETURN jsonb_build_object(
      'decision','REJECTED_INCOMPLETE',
      'reason_codes',jsonb_build_array('TARGET_IDENTITY_INCOMPLETE'),
      'scores',jsonb_build_object(
        'brand',0,'model',0,'title',0,'identifier',0,
        'identity',0,'accessory',0,'condition',0,'confidence',0
      ),
      'variant_match',jsonb_build_object('hard_match',false),
      'identifier_match',jsonb_build_object('hard_match',true)
    );
  END IF;

  SELECT concat_ws(
    ' ',
    p_target->>'brand',
    p_target->>'model_family',
    (
      SELECT string_agg(value,' ' ORDER BY ordinality)
      FROM jsonb_array_elements_text(
        COALESCE(p_target->'include_terms','[]'::jsonb)
      ) WITH ORDINALITY t(value,ordinality)
    )
  )
  INTO v_target_title;

  IF NULLIF(v_title,'') IS NULL THEN
    RETURN jsonb_build_object(
      'decision','REJECTED_INCOMPLETE',
      'reason_codes',jsonb_build_array('MISSING_RETURNED_TITLE'),
      'scores',jsonb_build_object(
        'brand',0,'model',0,'title',0,'identifier',0,
        'identity',0,'accessory',0,'condition',0,'confidence',0
      ),
      'variant_match',jsonb_build_object('hard_match',false),
      'identifier_match',jsonb_build_object('hard_match',true)
    );
  END IF;

  v_title_score:=retail.r1e_token_overlap(v_target_title,v_title);

  v_hard_include_terms:=COALESCE(
    (p_rules#>>'{identity,hard_include_terms}')::boolean,
    true
  );

  IF v_hard_include_terms THEN
    FOR v_term IN
      SELECT jsonb_array_elements_text(
        COALESCE(p_target->'include_terms','[]'::jsonb)
      )
    LOOP
      IF NOT retail.r1e_contains_phrase(
        concat_ws(
          ' ',
          v_title,
          v_model,
          p_returned#>>'{normalized_json,title}',
          p_returned#>>'{normalized_json,model}'
        ),
        v_term
      ) THEN
        v_missing_required_terms:=
          v_missing_required_terms||jsonb_build_array(v_term);
      END IF;
    END LOOP;

    IF jsonb_array_length(v_missing_required_terms)>0 THEN
      v_reasons:=v_reasons||
        jsonb_build_array('REQUIRED_TARGET_TERM_MISSING');
    END IF;
  END IF;

  IF NULLIF(p_target->>'brand','') IS NULL THEN
    v_brand_score:=100;
  ELSIF retail.r1e_normalize_text(v_brand)=
        retail.r1e_normalize_text(p_target->>'brand')
     OR retail.r1e_contains_phrase(v_title,p_target->>'brand') THEN
    v_brand_score:=100;
  ELSE
    v_brand_score:=0;
    v_reasons:=v_reasons||jsonb_build_array('BRAND_MISMATCH');
  END IF;

  IF NULLIF(p_target->>'model_family','') IS NULL THEN
    v_model_score:=100;
  ELSIF retail.r1e_contains_phrase(v_model,p_target->>'model_family')
     OR retail.r1e_contains_phrase(v_title,p_target->>'model_family') THEN
    v_model_score:=100;
  ELSE
    v_model_score:=retail.r1e_token_overlap(
      p_target->>'model_family',
      concat_ws(' ',v_model,v_title)
    );
    IF v_model_score<50 THEN
      v_reasons:=v_reasons||jsonb_build_array('MODEL_MISMATCH');
    END IF;
  END IF;

  v_variant:=retail.r1e_variant_match_document(
    p_target,p_returned,p_rules
  );

  IF COALESCE((v_variant->>'hard_match')::boolean,false) IS NOT TRUE THEN
    v_reasons:=v_reasons||jsonb_build_array('VARIANT_MISMATCH');
  END IF;

  v_identifier:=retail.r1e_identifier_match_document(
    p_target,p_returned
  );
  v_identifier_score:=(v_identifier->>'score')::numeric;

  IF COALESCE((v_identifier->>'hard_match')::boolean,true) IS NOT TRUE THEN
    v_reasons:=v_reasons||jsonb_build_array('IDENTIFIER_MISMATCH');
  END IF;

  v_brand_weight:=COALESCE((p_rules#>>'{identity,weights,brand}')::numeric,0.25);
  v_model_weight:=COALESCE((p_rules#>>'{identity,weights,model}')::numeric,0.35);
  v_title_weight:=COALESCE((p_rules#>>'{identity,weights,title}')::numeric,0.30);
  v_identifier_weight:=COALESCE((p_rules#>>'{identity,weights,identifier}')::numeric,0.10);

  -- Identifier weight participates only when an expected target identifier
  -- exists. Mere presence of a returned SKU/UPC/ASIN/EAN gives no credit.
  v_weight_denominator:=v_brand_weight+v_model_weight+v_title_weight;
  IF (v_identifier->>'expected_count')::integer>0 THEN
    v_weight_denominator:=v_weight_denominator+v_identifier_weight;
  END IF;

  IF v_weight_denominator<=0 THEN
    RAISE EXCEPTION 'R1E V2 identity weight denominator invalid';
  END IF;

  v_identity:=round(
    (
      v_brand_score*v_brand_weight+
      v_model_score*v_model_weight+
      v_title_score*v_title_weight+
      CASE
        WHEN (v_identifier->>'expected_count')::integer>0
        THEN v_identifier_score*v_identifier_weight
        ELSE 0
      END
    )/v_weight_denominator,
    4
  );

  -- Upstream exclusion terms remain authoritative.
  FOR v_term IN
    SELECT jsonb_array_elements_text(
      COALESCE(p_target->'exclude_terms','[]'::jsonb)
    )
  LOOP
    IF retail.r1e_contains_phrase(v_title,v_term) THEN
      v_accessory:=100;
      v_reasons:=v_reasons||
        jsonb_build_array('UPSTREAM_EXCLUDE_TERM:'||v_term);
      EXIT;
    END IF;
  END LOOP;

  IF v_accessory<100 THEN
    FOR v_term IN
      SELECT jsonb_array_elements_text(
        COALESCE(p_rules#>'{accessory,terms}','[]'::jsonb)
      )
    LOOP
      IF retail.r1e_contains_phrase(v_title,v_term)
         AND NOT retail.r1e_contains_phrase(v_target_title,v_term) THEN
        v_accessory:=100;
        v_reasons:=v_reasons||
          jsonb_build_array('ACCESSORY_TERM:'||v_term);
        EXIT;
      END IF;
    END LOOP;
  END IF;

  v_bundle_reject:=COALESCE(
    (p_rules#>>'{bundle,reject}')::boolean,false
  );

  FOR v_term IN
    SELECT jsonb_array_elements_text(
      COALESCE(p_rules#>'{bundle,terms}','[]'::jsonb)
    )
  LOOP
    IF retail.r1e_contains_phrase(v_title,v_term)
       AND NOT retail.r1e_contains_phrase(v_target_title,v_term) THEN
      v_reasons:=v_reasons||
        jsonb_build_array('BUNDLE_VARIANT_TERM:'||v_term);
      IF v_bundle_reject THEN
        v_accessory:=100;
      END IF;
      EXIT;
    END IF;
  END LOOP;

  IF v_condition IS NOT NULL
     AND jsonb_array_length(
       COALESCE(p_target->'allowed_product_conditions','[]'::jsonb)
     )>0 THEN
    v_condition_score:=0;
    FOR v_allowed IN
      SELECT jsonb_array_elements_text(
        p_target->'allowed_product_conditions'
      )
    LOOP
      IF retail.r1e_normalize_text(v_allowed)=
         retail.r1e_normalize_text(v_condition) THEN
        v_condition_score:=100;
        EXIT;
      END IF;
    END LOOP;

    IF v_condition_score=0 THEN
      v_reasons:=v_reasons||
        jsonb_build_array('CONDITION_NOT_ALLOWED');
    END IF;
  END IF;

  v_identity_min:=COALESCE(
    (p_rules#>>'{identity,min_score}')::numeric,80
  );
  v_require_brand:=COALESCE(
    (p_rules#>>'{identity,require_brand_match}')::boolean,true
  );
  v_min_model_score:=COALESCE(
    (p_rules#>>'{identity,min_model_score}')::numeric,70
  );
  v_min_title_score:=COALESCE(
    (p_rules#>>'{identity,min_title_score}')::numeric,55
  );
  v_accessory_threshold:=COALESCE(
    (p_rules#>>'{accessory,reject_threshold}')::numeric,80
  );

  IF p_rules#>>'{confidence,algorithm}'='weighted_identity_penalized' THEN
    v_confidence:=round(
      greatest(0,least(100,
        v_identity
        * CASE WHEN v_condition_score=100 THEN 1 ELSE 0.4 END
        * CASE WHEN v_accessory<v_accessory_threshold THEN 1 ELSE 0.2 END
        * CASE
            WHEN COALESCE((v_variant->>'hard_match')::boolean,false)
            THEN 1 ELSE 0.1
          END
      )),
      4
    );
  ELSE
    RAISE EXCEPTION 'Unsupported confidence algorithm';
  END IF;

  IF v_accessory>=v_accessory_threshold THEN
    v_decision:='REJECTED_ACCESSORY';
  ELSIF v_condition_score=0 THEN
    v_decision:='REJECTED_CONDITION';
  ELSIF COALESCE((v_identifier->>'hard_match')::boolean,true) IS NOT TRUE THEN
    v_decision:='REJECTED_IDENTITY';
  ELSIF COALESCE((v_variant->>'hard_match')::boolean,false) IS NOT TRUE THEN
    v_decision:='REJECTED_IDENTITY';
  ELSIF v_hard_include_terms
        AND jsonb_array_length(v_missing_required_terms)>0 THEN
    v_decision:='REJECTED_IDENTITY';
  ELSIF v_require_brand
        AND NULLIF(p_target->>'brand','') IS NOT NULL
        AND v_brand_score<100 THEN
    v_decision:='REJECTED_IDENTITY';
  ELSIF NULLIF(p_target->>'model_family','') IS NOT NULL
        AND v_model_score<v_min_model_score THEN
    v_decision:='REJECTED_IDENTITY';
  ELSIF v_title_score<v_min_title_score THEN
    v_decision:='REJECTED_IDENTITY';
  ELSIF v_identity<v_identity_min THEN
    v_decision:='REJECTED_IDENTITY';
  ELSE
    v_decision:='QUALIFIED';
  END IF;

  IF p_is_duplicate AND v_decision='QUALIFIED' THEN
    v_decision:='REJECTED_DUPLICATE';
    v_reasons:=v_reasons||
      jsonb_build_array('DUPLICATE_OBSERVATION');
  END IF;

  RETURN jsonb_build_object(
    'decision',v_decision,
    'reason_codes',v_reasons,
    'variant_match',v_variant,
    'identifier_match',v_identifier,
    'missing_required_terms',v_missing_required_terms,
    'scores',jsonb_build_object(
      'brand',v_brand_score,
      'model',v_model_score,
      'title',v_title_score,
      'identifier',v_identifier_score,
      'identity',v_identity,
      'accessory',v_accessory,
      'condition',v_condition_score,
      'confidence',v_confidence
    )
  );
END $$;

-- ---------- OBSERVATION FINGERPRINT -----------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_observation_document(
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
    o.estimated_total_cost,
    o.source_url,
    o.offer_hash
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
    'retail_product_id',p_product.id,
    'offer',jsonb_strip_nulls(jsonb_build_object(
      'effective_price',v_offer.effective_price,
      'currency_code',v_offer.currency_code,
      'availability',v_offer.availability,
      'quantity_available',v_offer.quantity_available,
      'shipping_cost_estimate',v_offer.shipping_cost_estimate,
      'estimated_total_cost',v_offer.estimated_total_cost,
      'source_url',v_offer.source_url,
      'offer_hash',v_offer.offer_hash
    )),
    'raw_payload_hash',p_capture.payload_hash
  ));
END $$;

-- ---------- R1E V2 EVALUATOR ------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_evaluate_capture_v2(
  p_raw_capture_id uuid,
  p_ruleset_id uuid,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text
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
    ARRAY[
      'RETAIL_R1E_QUALIFY_CAPTURE',
      'RETAIL_R1E_QUALIFY_BATCH'
    ]
  );

  PERFORM set_config('app.actor_type','worker',true);
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  IF retail.r1e_r1d_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1E V2 evaluation blocked: R1D binding stale';
  END IF;

  SELECT * INTO bind
  FROM retail.r1e_r1d_certification_binding
  WHERE singleton=true;

  SELECT * INTO rs
  FROM retail.r1e_match_rulesets
  WHERE id=p_ruleset_id
    AND certification_status='certified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1E V2 requires certified ruleset';
  END IF;

  PERFORM retail.r1e_validate_ruleset_v2(rs.rules_json);

  IF rs.rules_sha256<>retail.r1e_sha256_jsonb(rs.rules_json) THEN
    RAISE EXCEPTION 'R1E V2 ruleset SHA mismatch';
  END IF;

  SELECT * INTO cap
  FROM retail.raw_product_captures
  WHERE id=p_raw_capture_id;

  IF NOT FOUND OR cap.collection_run_id IS NULL THEN
    RAISE EXCEPTION 'R1E V2 capture missing or has no collection_run_id';
  END IF;

  -- Safe lineage lookup: malformed UUID metrics are ignored, never cast-fail
  -- the entire intake path.
  SELECT a.*
  INTO attempt
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
    )=cap.collection_run_id
  ORDER BY a.completed_at DESC NULLS LAST,a.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'R1E V2 lineage failed: no successful R1D attempt for collection_run_id';
  END IF;

  SELECT j.*
  INTO comp
  FROM retail.r1d_dispatch_jobs dj
  JOIN retail.search_job_compilations j
    ON j.id=dj.compilation_id
  WHERE dj.id=attempt.job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1E V2 immutable R1C compilation snapshot missing';
  END IF;

  v_target:=retail.r1e_compilation_target_document(comp.id);

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

  v_observation_doc:=retail.r1e_observation_document(
    cap,comp,rp
  );
  v_observation_fp:=retail.r1e_sha256_jsonb(v_observation_doc);

  -- Serialize exactly this observation scope. Same product in a different
  -- collection, ZIP/store, offer, price or inventory state has a different
  -- observation fingerprint and is not suppressed.
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
    v_match:=retail.r1e_match_documents_v2(
      v_target,v_returned,rs.rules_json,v_duplicate IS NOT NULL
    );
  END IF;

  v_evidence:=jsonb_build_object(
    'engine_version','r1e-v2.0.0',
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
    'match',v_match
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
    r1d_attempt_evidence_json,r1d_attempt_evidence_sha256
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
    rs.rules_sha256,'r1e-v2.0.0',
    v_product_fp,v_observation_fp,v_observation_doc,
    v_attempt_evidence,v_attempt_sha
  )
  ON CONFLICT(
    raw_capture_id,ruleset_id,r1d_certification_run_id
  )
  WHERE r1d_certification_run_id IS NOT NULL
  DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id
    FROM retail.r1e_qualification_results
    WHERE raw_capture_id=p_raw_capture_id
      AND ruleset_id=p_ruleset_id
      AND r1d_certification_run_id=bind.r1d_certification_run_id;
  END IF;

  RETURN v_id;
END $$;


CREATE OR REPLACE FUNCTION retail.r1e_upstream_identity_is_current(
  p_r1d_certification_run_id uuid,
  p_r1d_package_sha256 text
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      b.r1d_certification_run_id=p_r1d_certification_run_id
      AND b.r1d_package_sha256=p_r1d_package_sha256
      AND retail.r1e_r1d_binding_is_current()=true
    FROM retail.r1e_r1d_certification_binding b
    WHERE b.singleton=true
  ),false)
$$;

-- ---------- EXACT UPSTREAM CERTIFICATION CURRENTNESS -------------------------
ALTER TABLE retail.r1e_certification_runs
  ADD COLUMN IF NOT EXISTS certification_policy_id uuid
    REFERENCES retail.r1e_certification_policies(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS certification_policy_sha256 text;

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
      AND cr.certification_version='r1e-v2.0.0'
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
      AND retail.r1e_r1d_binding_is_current()=true
    FROM retail.r1e_certification_runs cr
    JOIN retail.r1e_match_rulesets rs
      ON rs.id=cr.ruleset_id
    JOIN retail.r1e_r1d_certification_binding b
      ON b.singleton=true
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

-- ---------- RESULT CURRENTNESS ----------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_result_is_current(
  p_result_id uuid
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      q.engine_version='r1e-v2.0.0'
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
      AND retail.r1e_latest_certification_is_current(q.ruleset_id)=true
    FROM retail.r1e_qualification_results q
    JOIN retail.r1e_r1d_certification_binding b
      ON b.singleton=true
    JOIN retail.r1e_match_rulesets rs
      ON rs.id=q.ruleset_id
    JOIN retail.search_job_compilations j
      ON j.id=q.compilation_id
    WHERE q.id=p_result_id
  ),false)
$$;

-- Immutable snapshot only: no mutable retail_products enrichment is part of
-- downstream authority.
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
  AND retail.r1e_result_is_current(q.id)=true;

COMMENT ON VIEW retail.r1e_effective_qualified_products IS
'R1E V2 sole downstream authority. Exposes immutable qualification snapshots only; current retail_products enrichment is intentionally excluded.';

-- ---------- SAFE PENDING INTAKE ---------------------------------------------
CREATE OR REPLACE VIEW retail.r1e_pending_captures AS
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
FROM retail.raw_product_captures c
JOIN LATERAL (
  SELECT a0.*
  FROM retail.r1d_dispatch_attempts a0
  JOIN retail.r1d_dispatch_jobs dj0
    ON dj0.id=a0.job_id
   AND dj0.status='succeeded'
  JOIN retail.search_job_compilations j0
    ON j0.id=dj0.compilation_id
   AND j0.platform_id=c.platform_id
  WHERE a0.success=true
    AND retail.r1e_try_uuid(
      a0.metrics_json->>'collection_run_id'
    )=c.collection_run_id
  ORDER BY a0.completed_at DESC NULLS LAST,a0.id DESC
  LIMIT 1
) a ON true
JOIN retail.r1d_dispatch_jobs dj
  ON dj.id=a.job_id
JOIN retail.search_job_compilations j
  ON j.id=dj.compilation_id
WHERE c.collection_run_id IS NOT NULL
  AND retail.r1e_r1d_binding_is_current()=true;


CREATE OR REPLACE FUNCTION retail.r1e_v2_certification_insert_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.certification_version='r1e-v2.0.0' THEN
    IF NEW.certification_policy_id IS NULL
       OR NEW.certification_policy_sha256 IS NULL THEN
      RAISE EXCEPTION 'R1E V2 certification requires bound immutable policy';
    END IF;
    IF NOT EXISTS(
      SELECT 1
      FROM retail.r1e_certification_policies p
      WHERE p.id=NEW.certification_policy_id
        AND p.certification_status='certified'
        AND p.policy_sha256=NEW.certification_policy_sha256
        AND p.policy_sha256=retail.r1e_sha256_jsonb(p.policy_json)
    ) THEN
      RAISE EXCEPTION 'R1E V2 certification policy identity invalid';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1e_v2_certification_insert_guard
ON retail.r1e_certification_runs;
CREATE TRIGGER trg_r1e_v2_certification_insert_guard
BEFORE INSERT ON retail.r1e_certification_runs
FOR EACH ROW EXECUTE FUNCTION retail.r1e_v2_certification_insert_guard();

-- ---------- PRIVILEGE HARDENING ---------------------------------------------
REVOKE ALL ON FUNCTION retail.r1e_try_uuid(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_bind_r1d_certification_v2(uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_assert_process_run(uuid,text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_certify_ruleset_v2(uuid,jsonb,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_validate_cert_policy(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_certify_policy(uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_try_observation_lock(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_attempt_evidence_document(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_compilation_target_document(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_evaluate_capture_v2(uuid,uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_result_is_current(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_upstream_identity_is_current(uuid,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION retail.r1e_bind_r1d_certification_v2(uuid,uuid,text,text)
  TO retail_r1e_certifier;
GRANT EXECUTE ON FUNCTION retail.r1e_evaluate_capture_v2(uuid,uuid,uuid,text,text)
  TO retail_r1e_worker;
GRANT EXECUTE ON FUNCTION retail.r1e_certify_ruleset_v2(uuid,jsonb,uuid,text,text)
  TO retail_r1e_certifier;
GRANT EXECUTE ON FUNCTION retail.r1e_certify_policy(uuid,uuid,text,text)
  TO retail_r1e_certifier;

COMMIT;
