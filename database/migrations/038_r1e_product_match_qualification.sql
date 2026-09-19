BEGIN;

CREATE SCHEMA IF NOT EXISTS retail;
CREATE SCHEMA IF NOT EXISTS retail_audit;

-- ============================================================================
-- TCDS RETAIL R1E — RETURNED PRODUCT MATCH & DISCOVERY QUALIFICATION ENGINE
-- GREEN TIER 1 HARDENED V1 FREEZE CANDIDATE
--
-- Sole purpose:
--   Determine whether a returned retail item is the intended product candidate
--   for the originating R1A/R1B/R1C search authority.
--
-- R1E OWNS:
--   identity match
--   accessory / bundle / variant rejection
--   condition compatibility
--   retailer-returned duplicate suppression
--   match confidence
--   discovery qualification evidence
--
-- R1E DOES NOT OWN:
--   profit calculation
--   demand scoring
--   capital safety
--   BUY / NO-BUY
--   checkout / purchasing
-- ============================================================================

DO $$
DECLARE
  v_r1d record;
BEGIN
  IF to_regclass('retail.r1d_v2_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1d_v2_state
       WHERE singleton=true AND hardening_version='2.0.0'
     ) THEN
    RAISE EXCEPTION 'R1E requires R1D V2 hardening 2.0.0';
  END IF;

  IF to_regclass('retail.r1d_certification_runs') IS NULL THEN
    RAISE EXCEPTION 'R1E requires R1D certification authority';
  END IF;

  SELECT * INTO v_r1d
  FROM retail.r1d_certification_runs
  WHERE completed_at IS NOT NULL
  ORDER BY completed_at DESC,id::text DESC
  LIMIT 1;

  IF NOT FOUND
     OR v_r1d.certification_status<>'CERTIFIED'
     OR v_r1d.certification_version<>'r1d-v2.0.0' THEN
    RAISE EXCEPTION 'R1E requires latest R1D = r1d-v2.0.0 CERTIFIED';
  END IF;

  IF to_regclass('retail.raw_product_captures') IS NULL
     OR to_regclass('retail.retail_products') IS NULL
     OR to_regclass('retail.retail_offer_snapshots') IS NULL THEN
    RAISE EXCEPTION 'R1E retail data-plane dependencies missing';
  END IF;

  IF to_regclass('arb.process_registry') IS NULL
     OR to_regclass('arb.process_runs') IS NULL
     OR to_regclass('retail_audit.retail_change_log') IS NULL THEN
    RAISE EXCEPTION 'R1E provenance/audit dependencies missing';
  END IF;
END $$;

CREATE TABLE retail.r1e_schema_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  schema_version text NOT NULL,
  doctrine text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user
);

INSERT INTO retail.r1e_schema_state(singleton,schema_version,doctrine)
VALUES(
  true,'1.0.0',
  'R1E qualifies returned products against exact upstream search intent. It never calculates profitability or authorizes purchase.'
);

CREATE OR REPLACE FUNCTION retail.r1e_sha256_text(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT retail.r1c_sha256_text(p_text) $$;

CREATE OR REPLACE FUNCTION retail.r1e_sha256_jsonb(p_doc jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT retail.r1e_sha256_text(p_doc::text) $$;

-- ---------- RBAC -------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1e_reader') THEN
    CREATE ROLE retail_r1e_reader NOLOGIN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1e_worker') THEN
    CREATE ROLE retail_r1e_worker NOLOGIN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1e_certifier') THEN
    CREATE ROLE retail_r1e_certifier NOLOGIN;
  END IF;
END $$;

INSERT INTO arb.process_registry(
  process_name,phase_no,process_group,description,owner_team,active_flag
)
VALUES
('RETAIL_R1E_R1D_BIND',2,'RETAIL_AUTOMATION',
 'Bind R1E to exact latest certified R1D V2 authority.',
 'TCDS Retail Automation',true),
('RETAIL_R1E_RULESET_REGISTER',2,'RETAIL_AUTOMATION',
 'Register immutable returned-product matching ruleset.',
 'TCDS Retail Automation',true),
('RETAIL_R1E_RULESET_CERTIFY',2,'RETAIL_AUTOMATION',
 'Certify immutable returned-product matching ruleset.',
 'TCDS Retail Automation',true),
('RETAIL_R1E_QUALIFY_CAPTURE',2,'RETAIL_AUTOMATION',
 'Evaluate one returned retail capture against its originating search intent.',
 'TCDS Retail Automation',true),
('RETAIL_R1E_QUALIFY_BATCH',2,'RETAIL_AUTOMATION',
 'Batch-evaluate unqualified returned captures.',
 'TCDS Retail Automation',true),
('RETAIL_R1E_CERTIFY',2,'RETAIL_AUTOMATION',
 'Execute R1E freeze-gate certification and deterministic replay.',
 'TCDS Retail Automation',true)
ON CONFLICT(process_name) DO NOTHING;

-- ---------- R1D BINDING ------------------------------------------------------
CREATE TABLE retail.r1e_r1d_certification_binding(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  r1d_certification_run_id uuid NOT NULL
    REFERENCES retail.r1d_certification_runs(id) ON DELETE RESTRICT,
  r1d_certification_version text NOT NULL,
  r1d_package_sha256 text NOT NULL CHECK(r1d_package_sha256 ~ '^[0-9a-f]{64}$'),
  r1d_evidence_manifest_sha256 text NOT NULL CHECK(r1d_evidence_manifest_sha256 ~ '^[0-9a-f]{64}$'),
  bound_by text NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now(),
  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE retail.r1e_r1d_binding_history(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  r1d_certification_run_id uuid NOT NULL REFERENCES retail.r1d_certification_runs(id) ON DELETE RESTRICT,
  r1d_package_sha256 text NOT NULL,
  r1d_evidence_manifest_sha256 text NOT NULL,
  bound_by text NOT NULL,
  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1e_r1d_binding_is_current()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      b.r1d_certification_version='r1d-v2.0.0'
      AND cr.id=b.r1d_certification_run_id
      AND cr.certification_status='CERTIFIED'
      AND cr.certification_version='r1d-v2.0.0'
      AND cr.id=(
        SELECT x.id
        FROM retail.r1d_certification_runs x
        WHERE x.completed_at IS NOT NULL
        ORDER BY x.completed_at DESC,x.id::text DESC
        LIMIT 1
      )
      AND cr.r1d_package_sha256=b.r1d_package_sha256
      AND cr.evidence_manifest_sha256=b.r1d_evidence_manifest_sha256
    FROM retail.r1e_r1d_certification_binding b
    JOIN retail.r1d_certification_runs cr ON cr.id=b.r1d_certification_run_id
    WHERE b.singleton=true
  ),false)
$$;

CREATE OR REPLACE FUNCTION retail.r1e_bind_r1d_certification(
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
    RAISE EXCEPTION 'R1E bind blocked: supplied R1D certification is not latest';
  END IF;

  SELECT * INTO cr
  FROM retail.r1d_certification_runs
  WHERE id=p_r1d_certification_run_id
    AND certification_status='CERTIFIED'
    AND certification_version='r1d-v2.0.0';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1E bind requires R1D V2 CERTIFIED run';
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

-- ---------- RULESET AUTHORITY ------------------------------------------------
CREATE TABLE retail.r1e_match_rulesets(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ruleset_code text NOT NULL,
  ruleset_version text NOT NULL,
  rules_json jsonb NOT NULL CHECK(jsonb_typeof(rules_json)='object'),
  rules_sha256 text NOT NULL CHECK(rules_sha256 ~ '^[0-9a-f]{64}$'),
  certification_status text NOT NULL DEFAULT 'draft'
    CHECK(certification_status IN('draft','certified','suspended','retired')),
  qa_evidence_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(qa_evidence_json)='object'),
  qa_evidence_sha256 text NOT NULL CHECK(qa_evidence_sha256 ~ '^[0-9a-f]{64}$'),
  certified_by text,
  certified_at timestamptz,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(ruleset_code,ruleset_version)
);

CREATE OR REPLACE FUNCTION retail.r1e_prepare_ruleset()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.rules_sha256:=retail.r1e_sha256_jsonb(NEW.rules_json);
  NEW.qa_evidence_sha256:=retail.r1e_sha256_jsonb(NEW.qa_evidence_json);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1e_prepare_ruleset
BEFORE INSERT OR UPDATE ON retail.r1e_match_rulesets
FOR EACH ROW EXECUTE FUNCTION retail.r1e_prepare_ruleset();

CREATE OR REPLACE FUNCTION retail.r1e_ruleset_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1E rulesets cannot be deleted';
  END IF;

  IF OLD.certification_status='certified' THEN
    IF (to_jsonb(NEW)-ARRAY['certification_status'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['certification_status']) THEN
      RAISE EXCEPTION 'Certified R1E ruleset immutable; create new version';
    END IF;
    IF NEW.certification_status NOT IN('certified','suspended','retired') THEN
      RAISE EXCEPTION 'Invalid certified ruleset transition';
    END IF;
  END IF;

  IF OLD.certification_status IN('suspended','retired')
     AND NEW.certification_status<>OLD.certification_status
     AND NOT (OLD.certification_status='suspended' AND NEW.certification_status='retired') THEN
    RAISE EXCEPTION 'Suspended/retired ruleset cannot be reactivated';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1e_ruleset_guard
BEFORE UPDATE OR DELETE ON retail.r1e_match_rulesets
FOR EACH ROW EXECUTE FUNCTION retail.r1e_ruleset_guard();

CREATE UNIQUE INDEX uq_r1e_one_certified_ruleset
ON retail.r1e_match_rulesets(ruleset_code)
WHERE certification_status='certified';


CREATE OR REPLACE FUNCTION retail.r1e_validate_ruleset(p_rules jsonb)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_sum numeric;
  v_min numeric;
  v_model numeric;
  v_title numeric;
  v_accessory numeric;
BEGIN
  IF p_rules IS NULL OR jsonb_typeof(p_rules)<>'object' THEN
    RAISE EXCEPTION 'R1E rules must be JSON object';
  END IF;

  IF NOT (
    p_rules ? 'identity'
    AND p_rules ? 'accessory'
    AND p_rules ? 'condition'
    AND p_rules ? 'confidence'
    AND p_rules ? 'duplicate'
    AND p_rules ? 'bundle'
  ) THEN
    RAISE EXCEPTION 'Ruleset missing mandatory rule family';
  END IF;

  v_sum:=
    COALESCE((p_rules#>>'{identity,weights,brand}')::numeric,0)+
    COALESCE((p_rules#>>'{identity,weights,model}')::numeric,0)+
    COALESCE((p_rules#>>'{identity,weights,title}')::numeric,0)+
    COALESCE((p_rules#>>'{identity,weights,identifier}')::numeric,0);

  IF abs(v_sum-1)>0.0001 THEN
    RAISE EXCEPTION 'Identity weights must sum to 1';
  END IF;

  v_min:=COALESCE((p_rules#>>'{identity,min_score}')::numeric,-1);
  v_model:=COALESCE((p_rules#>>'{identity,min_model_score}')::numeric,-1);
  v_title:=COALESCE((p_rules#>>'{identity,min_title_score}')::numeric,-1);
  v_accessory:=COALESCE(
    (p_rules#>>'{accessory,reject_threshold}')::numeric,-1
  );

  IF v_min<0 OR v_min>100
     OR v_model<0 OR v_model>100
     OR v_title<0 OR v_title>100
     OR v_accessory<0 OR v_accessory>100 THEN
    RAISE EXCEPTION 'Ruleset score thresholds must be 0..100';
  END IF;

  IF jsonb_typeof(COALESCE(p_rules#>'{accessory,terms}','[]'::jsonb))<>'array'
     OR jsonb_typeof(COALESCE(p_rules#>'{bundle,terms}','[]'::jsonb))<>'array' THEN
    RAISE EXCEPTION 'Accessory/bundle terms must be arrays';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION retail.r1e_certify_ruleset(
  p_ruleset_id uuid,
  p_qa_evidence jsonb,
  p_certifier text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  r record;
BEGIN
  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id',p_certifier,true);
  PERFORM set_config('app.actor_name',p_certifier,true);

  SELECT * INTO r
  FROM retail.r1e_match_rulesets
  WHERE id=p_ruleset_id FOR UPDATE;

  IF NOT FOUND OR r.certification_status<>'draft' THEN
    RAISE EXCEPTION 'Ruleset missing/not eligible';
  END IF;

  PERFORM retail.r1e_validate_ruleset(r.rules_json);

  IF p_qa_evidence IS NULL OR p_qa_evidence='{}'::jsonb THEN
    RAISE EXCEPTION 'Non-empty QA evidence required';
  END IF;

  IF NOT (
    r.rules_json ? 'identity'
    AND r.rules_json ? 'accessory'
    AND r.rules_json ? 'condition'
    AND r.rules_json ? 'confidence'
    AND r.rules_json ? 'duplicate'
    AND r.rules_json ? 'bundle'
  ) THEN
    RAISE EXCEPTION 'Ruleset missing mandatory rule families';
  END IF;

  UPDATE retail.r1e_match_rulesets
  SET certification_status='suspended'
  WHERE ruleset_code=r.ruleset_code
    AND id<>r.id
    AND certification_status='certified';

  UPDATE retail.r1e_match_rulesets
  SET qa_evidence_json=p_qa_evidence,
      certification_status='certified',
      certified_by=p_certifier,
      certified_at=now()
  WHERE id=r.id;
END $$;

-- ---------- QUALIFICATION RESULT --------------------------------------------
CREATE TABLE retail.r1e_qualification_results(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_capture_id uuid NOT NULL REFERENCES retail.raw_product_captures(id) ON DELETE RESTRICT,
  retail_product_id uuid REFERENCES retail.retail_products(id) ON DELETE RESTRICT,
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  compilation_id uuid NOT NULL REFERENCES retail.search_job_compilations(id) ON DELETE RESTRICT,
  route_id uuid NOT NULL REFERENCES retail.search_route_bindings(id) ON DELETE RESTRICT,
  target_id uuid NOT NULL REFERENCES retail.search_targets(id) ON DELETE RESTRICT,
  ruleset_id uuid NOT NULL REFERENCES retail.r1e_match_rulesets(id) ON DELETE RESTRICT,

  returned_identity_json jsonb NOT NULL CHECK(jsonb_typeof(returned_identity_json)='object'),
  target_identity_json jsonb NOT NULL CHECK(jsonb_typeof(target_identity_json)='object'),

  identity_score numeric NOT NULL CHECK(identity_score BETWEEN 0 AND 100),
  accessory_score numeric NOT NULL CHECK(accessory_score BETWEEN 0 AND 100),
  condition_score numeric NOT NULL CHECK(condition_score BETWEEN 0 AND 100),
  confidence_score numeric NOT NULL CHECK(confidence_score BETWEEN 0 AND 100),

  duplicate_fingerprint text NOT NULL CHECK(duplicate_fingerprint ~ '^[0-9a-f]{64}$'),
  duplicate_of_result_id uuid REFERENCES retail.r1e_qualification_results(id) ON DELETE RESTRICT,

  decision text NOT NULL CHECK(decision IN(
    'QUALIFIED','REJECTED_IDENTITY','REJECTED_ACCESSORY',
    'REJECTED_CONDITION','REJECTED_DUPLICATE','REJECTED_INCOMPLETE'
  )),
  reason_codes jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(reason_codes)='array'),
  evidence_json jsonb NOT NULL CHECK(jsonb_typeof(evidence_json)='object'),
  evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),

  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  qualified_by text NOT NULL,
  qualified_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE(raw_capture_id,ruleset_id)
);

CREATE INDEX idx_r1e_results_decision
ON retail.r1e_qualification_results(decision,platform_id,qualified_at);

CREATE INDEX idx_r1e_results_target
ON retail.r1e_qualification_results(target_id,decision);

CREATE INDEX idx_r1e_duplicate_fingerprint
ON retail.r1e_qualification_results(duplicate_fingerprint);

CREATE OR REPLACE FUNCTION retail.r1e_result_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1E qualification results are immutable';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1e_result_guard
BEFORE UPDATE OR DELETE ON retail.r1e_qualification_results
FOR EACH ROW EXECUTE FUNCTION retail.r1e_result_guard();

-- ---------- QUALIFICATION AUTHORITY -----------------------------------------
CREATE OR REPLACE FUNCTION retail.r1e_normalize_text(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT NULLIF(
    lower(regexp_replace(
      regexp_replace(COALESCE(p_text,''),'[^a-zA-Z0-9]+',' ','g'),
      '\s+',' ','g'
    )),
    ''
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1e_token_overlap(
  p_target text,
  p_returned text
)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  WITH t AS (
    SELECT DISTINCT x
    FROM unnest(regexp_split_to_array(COALESCE(retail.r1e_normalize_text(p_target),''),'\s+')) x
    WHERE x<>''
  ),
  r AS (
    SELECT DISTINCT x
    FROM unnest(regexp_split_to_array(COALESCE(retail.r1e_normalize_text(p_returned),''),'\s+')) x
    WHERE x<>''
  ),
  c AS (
    SELECT count(*)::numeric common FROM t JOIN r USING(x)
  ),
  n AS (
    SELECT count(*)::numeric total FROM t
  )
  SELECT CASE WHEN n.total=0 THEN 0 ELSE round(100*c.common/n.total,4) END
  FROM c,n
$$;

CREATE OR REPLACE FUNCTION retail.r1e_match_documents(
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
  v_identity_min numeric;
  v_min_model_score numeric;
  v_min_title_score numeric;
  v_require_brand boolean;
  v_accessory_threshold numeric;
  v_bundle_reject boolean;

  v_decision text;
  v_reasons jsonb:='[]'::jsonb;
  v_term text;
  v_allowed text;
BEGIN
  IF jsonb_typeof(p_target)<>'object'
     OR jsonb_typeof(p_returned)<>'object'
     OR jsonb_typeof(p_rules)<>'object' THEN
    RAISE EXCEPTION 'R1E match documents must be JSON objects';
  END IF;

  IF NULLIF(p_target->>'brand','') IS NULL
     AND NULLIF(p_target->>'model_family','') IS NULL THEN
    RETURN jsonb_build_object(
      'decision','REJECTED_INCOMPLETE',
      'reason_codes',jsonb_build_array('TARGET_IDENTITY_INCOMPLETE'),
      'scores',jsonb_build_object(
        'brand',0,'model',0,'title',0,'identifier',0,
        'identity',0,'accessory',0,'condition',0,'confidence',0
      )
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
      )
    );
  END IF;

  v_title_score:=retail.r1e_token_overlap(v_target_title,v_title);

  IF NULLIF(p_target->>'brand','') IS NULL THEN
    v_brand_score:=100;
  ELSIF retail.r1e_normalize_text(v_brand)=
        retail.r1e_normalize_text(p_target->>'brand')
     OR retail.r1e_normalize_text(v_title)
        LIKE '%'||retail.r1e_normalize_text(p_target->>'brand')||'%' THEN
    v_brand_score:=100;
  ELSE
    v_brand_score:=0;
    v_reasons:=v_reasons||jsonb_build_array('BRAND_MISMATCH');
  END IF;

  IF NULLIF(p_target->>'model_family','') IS NULL THEN
    v_model_score:=100;
  ELSIF retail.r1e_normalize_text(v_model)
        LIKE '%'||retail.r1e_normalize_text(p_target->>'model_family')||'%'
     OR retail.r1e_normalize_text(v_title)
        LIKE '%'||retail.r1e_normalize_text(p_target->>'model_family')||'%' THEN
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

  v_identifier_score:=CASE
    WHEN NULLIF(p_returned->>'upc','') IS NOT NULL
      OR NULLIF(p_returned->>'ean','') IS NOT NULL
      OR NULLIF(p_returned->>'asin','') IS NOT NULL
      OR NULLIF(p_returned->>'sku','') IS NOT NULL
    THEN 100 ELSE 50
  END;

  v_brand_weight:=COALESCE((p_rules#>>'{identity,weights,brand}')::numeric,0.25);
  v_model_weight:=COALESCE((p_rules#>>'{identity,weights,model}')::numeric,0.35);
  v_title_weight:=COALESCE((p_rules#>>'{identity,weights,title}')::numeric,0.30);
  v_identifier_weight:=COALESCE((p_rules#>>'{identity,weights,identifier}')::numeric,0.10);

  IF abs(
    v_brand_weight+v_model_weight+v_title_weight+v_identifier_weight-1
  )>0.0001 THEN
    RAISE EXCEPTION 'R1E identity weights must sum to 1';
  END IF;

  v_identity:=round(
    v_brand_score*v_brand_weight+
    v_model_score*v_model_weight+
    v_title_score*v_title_weight+
    v_identifier_score*v_identifier_weight,
    4
  );

  FOR v_term IN
    SELECT jsonb_array_elements_text(
      COALESCE(p_target->'exclude_terms','[]'::jsonb)
    )
  LOOP
    IF retail.r1e_normalize_text(v_title)
       LIKE '%'||retail.r1e_normalize_text(v_term)||'%' THEN
      v_accessory:=100;
      v_reasons:=v_reasons||jsonb_build_array(
        'UPSTREAM_EXCLUDE_TERM:'||v_term
      );
      EXIT;
    END IF;
  END LOOP;

  IF v_accessory<100 THEN
    FOR v_term IN
      SELECT jsonb_array_elements_text(
        COALESCE(p_rules#>'{accessory,terms}','[]'::jsonb)
      )
    LOOP
      IF retail.r1e_normalize_text(v_title)
         LIKE '%'||retail.r1e_normalize_text(v_term)||'%'
         AND retail.r1e_normalize_text(v_target_title)
             NOT LIKE '%'||retail.r1e_normalize_text(v_term)||'%' THEN
        v_accessory:=100;
        v_reasons:=v_reasons||jsonb_build_array(
          'ACCESSORY_TERM:'||v_term
        );
        EXIT;
      END IF;
    END LOOP;
  END IF;

  v_bundle_reject:=COALESCE(
    (p_rules#>>'{bundle,reject}')::boolean,
    false
  );

  FOR v_term IN
    SELECT jsonb_array_elements_text(
      COALESCE(p_rules#>'{bundle,terms}','[]'::jsonb)
    )
  LOOP
    IF retail.r1e_normalize_text(v_title)
       LIKE '%'||retail.r1e_normalize_text(v_term)||'%'
       AND retail.r1e_normalize_text(v_target_title)
           NOT LIKE '%'||retail.r1e_normalize_text(v_term)||'%' THEN
      v_reasons:=v_reasons||jsonb_build_array(
        'BUNDLE_VARIANT_TERM:'||v_term
      );
      IF v_bundle_reject THEN
        v_accessory:=100;
      END IF;
      EXIT;
    END IF;
  END LOOP;

  IF v_condition IS NOT NULL
     AND jsonb_array_length(
       COALESCE(p_target->'allowed_conditions','[]'::jsonb)
     )>0 THEN
    v_condition_score:=0;
    FOR v_allowed IN
      SELECT jsonb_array_elements_text(p_target->'allowed_conditions')
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

  v_confidence:=round(
    greatest(0,least(100,
      v_identity
      * CASE WHEN v_condition_score=100 THEN 1 ELSE 0.4 END
      * CASE WHEN v_accessory<v_accessory_threshold THEN 1 ELSE 0.2 END
    )),
    4
  );

  IF v_accessory>=v_accessory_threshold THEN
    v_decision:='REJECTED_ACCESSORY';
  ELSIF v_condition_score=0 THEN
    v_decision:='REJECTED_CONDITION';
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
    v_reasons:=v_reasons||jsonb_build_array('DUPLICATE_RETURN');
  END IF;

  RETURN jsonb_build_object(
    'decision',v_decision,
    'reason_codes',v_reasons,
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

CREATE OR REPLACE FUNCTION retail.r1e_evaluate_capture(
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
  r record;
  rs retail.r1e_match_rulesets%ROWTYPE;
  v_returned jsonb;
  v_target jsonb;
  v_match jsonb;
  v_fingerprint text;
  v_duplicate uuid;
  v_evidence jsonb;
  v_id uuid;
BEGIN
  PERFORM set_config('app.actor_type','worker',true);
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  IF retail.r1e_r1d_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1E evaluation blocked: R1D binding stale';
  END IF;

  SELECT * INTO rs
  FROM retail.r1e_match_rulesets
  WHERE id=p_ruleset_id
    AND certification_status='certified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Certified R1E ruleset required';
  END IF;

  IF rs.rules_sha256<>retail.r1e_sha256_jsonb(rs.rules_json) THEN
    RAISE EXCEPTION 'R1E ruleset authority hash mismatch';
  END IF;

  SELECT * INTO cap
  FROM retail.raw_product_captures
  WHERE id=p_raw_capture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Raw capture missing';
  END IF;

  IF cap.collection_run_id IS NULL THEN
    RAISE EXCEPTION 'R1E fail-closed: raw capture has no collection_run_id';
  END IF;

  SELECT
    j.id compilation_id,
    j.route_id,
    j.target_id,
    j.platform_id,
    er.target_code,
    er.brand,
    er.model_family,
    er.category_key,
    er.include_terms,
    er.exclude_terms,
    er.allowed_product_conditions,
    a.id attempt_id
  INTO r
  FROM retail.r1d_dispatch_attempts a
  JOIN retail.r1d_dispatch_jobs dj ON dj.id=a.job_id
  JOIN retail.search_job_compilations j ON j.id=dj.compilation_id
  JOIN retail.effective_search_routes er ON er.route_id=j.route_id
  WHERE a.success=true
    AND dj.status='succeeded'
    AND j.platform_id=cap.platform_id
    AND nullif(a.metrics_json->>'collection_run_id','') IS NOT NULL
    AND (a.metrics_json->>'collection_run_id')::uuid=cap.collection_run_id
  ORDER BY a.completed_at DESC NULLS LAST,a.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'R1E fail-closed: capture cannot be bound to successful R1D attempt using metrics_json.collection_run_id';
  END IF;

  SELECT * INTO rp
  FROM retail.retail_products p
  WHERE p.platform_id=cap.platform_id
    AND p.platform_product_key=cap.platform_product_key
  ORDER BY p.last_seen_at DESC,p.id::text
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
    'source_url',cap.source_url
  ));

  v_target:=jsonb_strip_nulls(jsonb_build_object(
    'target_code',r.target_code,
    'brand',r.brand,
    'model_family',r.model_family,
    'category_key',r.category_key,
    'include_terms',r.include_terms,
    'exclude_terms',r.exclude_terms,
    'allowed_conditions',r.allowed_product_conditions
  ));

  v_fingerprint:=retail.r1e_sha256_jsonb(
    jsonb_strip_nulls(jsonb_build_object(
      'platform_id',r.platform_id,
      'target_id',r.target_id,
      'platform_product_key',cap.platform_product_key,
      'upc',rp.upc,
      'ean',rp.ean,
      'asin',rp.asin,
      'sku',rp.sku,
      'normalized_title',retail.r1e_normalize_text(
        COALESCE(rp.title,cap.raw_title)
      ),
      'normalized_model',retail.r1e_normalize_text(
        COALESCE(
          rp.model_number,
          rp.normalized_json->>'model',
          rp.normalized_json->>'model_number',
          cap.raw_payload->>'model',
          cap.raw_payload->>'model_number'
        )
      )
    ))
  );

  SELECT id INTO v_duplicate
  FROM retail.r1e_qualification_results
  WHERE duplicate_fingerprint=v_fingerprint
    AND ruleset_id=p_ruleset_id
    AND raw_capture_id<>p_raw_capture_id
  ORDER BY qualified_at,id::text
  LIMIT 1;

  IF rp.id IS NULL THEN
    v_match:=jsonb_build_object(
      'decision','REJECTED_INCOMPLETE',
      'reason_codes',jsonb_build_array('CANONICAL_RETAIL_PRODUCT_MISSING'),
      'scores',jsonb_build_object(
        'brand',0,'model',0,'title',0,'identifier',0,
        'identity',0,'accessory',0,'condition',0,'confidence',0
      )
    );
  ELSE
    v_match:=retail.r1e_match_documents(
      v_target,v_returned,rs.rules_json,v_duplicate IS NOT NULL
    );
  END IF;

  v_evidence:=jsonb_build_object(
    'r1d_certification_binding',
      (SELECT to_jsonb(b)
       FROM retail.r1e_r1d_certification_binding b
       WHERE singleton=true),
    'r1d_attempt_id',r.attempt_id,
    'collection_run_id',cap.collection_run_id,
    'compilation_id',r.compilation_id,
    'route_id',r.route_id,
    'target_id',r.target_id,
    'raw_payload_hash',cap.payload_hash,
    'ruleset_sha256',rs.rules_sha256,
    'returned_identity',v_returned,
    'target_identity',v_target,
    'scores',v_match->'scores',
    'decision',v_match->>'decision',
    'reason_codes',v_match->'reason_codes',
    'duplicate_fingerprint',v_fingerprint
  );

  INSERT INTO retail.r1e_qualification_results(
    raw_capture_id,retail_product_id,platform_id,
    compilation_id,route_id,target_id,ruleset_id,
    returned_identity_json,target_identity_json,
    identity_score,accessory_score,condition_score,confidence_score,
    duplicate_fingerprint,duplicate_of_result_id,
    decision,reason_codes,evidence_json,evidence_sha256,
    source_process_run_id,source_correlation_id,qualified_by
  )
  VALUES(
    p_raw_capture_id,rp.id,r.platform_id,
    r.compilation_id,r.route_id,r.target_id,p_ruleset_id,
    v_returned,v_target,
    COALESCE((v_match#>>'{scores,identity}')::numeric,0),
    COALESCE((v_match#>>'{scores,accessory}')::numeric,0),
    COALESCE((v_match#>>'{scores,condition}')::numeric,0),
    COALESCE((v_match#>>'{scores,confidence}')::numeric,0),
    v_fingerprint,v_duplicate,
    v_match->>'decision',
    COALESCE(v_match->'reason_codes','[]'::jsonb),
    v_evidence,retail.r1e_sha256_jsonb(v_evidence),
    p_process_run_id,p_correlation_id,p_actor
  )
  ON CONFLICT(raw_capture_id,ruleset_id) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id
    FROM retail.r1e_qualification_results
    WHERE raw_capture_id=p_raw_capture_id
      AND ruleset_id=p_ruleset_id;
  END IF;

  RETURN v_id;
END $$;

-- ---------- EFFECTIVE QUALIFIED OUTPUT --------------------------------------
CREATE OR REPLACE VIEW retail.r1e_effective_qualified_products AS
SELECT
  q.*,
  rp.platform_product_key,
  rp.title,
  rp.brand,
  rp.model_number,
  rp.upc,
  rp.ean,
  rp.asin,
  rp.sku,
  rp.normalized_json
FROM retail.r1e_qualification_results q
JOIN retail.retail_products rp
  ON rp.id=q.retail_product_id
 AND rp.platform_id=q.platform_id
WHERE q.decision='QUALIFIED'
  AND retail.r1e_r1d_binding_is_current()=true
  AND EXISTS(
    SELECT 1 FROM retail.r1e_match_rulesets rs
    WHERE rs.id=q.ruleset_id
      AND rs.certification_status='certified'
      AND rs.rules_sha256=retail.r1e_sha256_jsonb(rs.rules_json)
  );

COMMENT ON VIEW retail.r1e_effective_qualified_products IS
'R1E sole downstream qualified-discovery authority. Contains product-match truth only; no profitability or purchase authority.';


-- ---------- LINEAGE / PENDING INTAKE ----------------------------------------
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
    AND nullif(a0.metrics_json->>'collection_run_id','') IS NOT NULL
    AND (a0.metrics_json->>'collection_run_id')::uuid=c.collection_run_id
  ORDER BY a0.completed_at DESC NULLS LAST,a0.id DESC
  LIMIT 1
) a ON true
JOIN retail.r1d_dispatch_jobs dj ON dj.id=a.job_id
JOIN retail.search_job_compilations j ON j.id=dj.compilation_id
WHERE c.collection_run_id IS NOT NULL
  AND retail.r1e_r1d_binding_is_current()=true;

COMMENT ON VIEW retail.r1e_pending_captures IS
'R1E intake authority: captures with exact successful R1D attempt lineage through metrics_json.collection_run_id.';

-- ---------- CERTIFICATION QA FIXTURES ---------------------------------------
CREATE TABLE retail.r1e_qa_fixtures(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fixture_code text NOT NULL UNIQUE,
  ruleset_code text NOT NULL,
  target_identity_json jsonb NOT NULL CHECK(jsonb_typeof(target_identity_json)='object'),
  returned_identity_json jsonb NOT NULL CHECK(jsonb_typeof(returned_identity_json)='object'),
  expected_decision text NOT NULL CHECK(expected_decision IN(
    'QUALIFIED','REJECTED_IDENTITY','REJECTED_ACCESSORY',
    'REJECTED_CONDITION','REJECTED_DUPLICATE','REJECTED_INCOMPLETE'
  )),
  fixture_class text NOT NULL CHECK(fixture_class IN(
    'positive_identity','wrong_brand','wrong_model','accessory',
    'condition','duplicate','incomplete','bundle_variant'
  )),
  expected_reason_family text,
  fixture_sha256 text NOT NULL CHECK(fixture_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1e_fixture_document(
  p_row retail.r1e_qa_fixtures
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'fixture_code',p_row.fixture_code,
    'ruleset_code',p_row.ruleset_code,
    'target_identity_json',p_row.target_identity_json,
    'returned_identity_json',p_row.returned_identity_json,
    'expected_decision',p_row.expected_decision,
    'fixture_class',p_row.fixture_class,
    'expected_reason_family',p_row.expected_reason_family
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1e_prepare_fixture()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.fixture_sha256:=retail.r1e_sha256_jsonb(
    retail.r1e_fixture_document(NEW)
  );
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1e_prepare_fixture
BEFORE INSERT OR UPDATE ON retail.r1e_qa_fixtures
FOR EACH ROW EXECUTE FUNCTION retail.r1e_prepare_fixture();

CREATE OR REPLACE FUNCTION retail.r1e_fixture_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1E QA fixtures cannot be deleted; deactivate them';
  END IF;
  IF OLD.active=true THEN
    IF (to_jsonb(NEW)-ARRAY['active'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['active']) THEN
      RAISE EXCEPTION 'Active R1E fixture immutable; create replacement fixture';
    END IF;
  ELSIF NEW.active<>OLD.active THEN
    RAISE EXCEPTION 'Inactive R1E fixture cannot be reactivated';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1e_fixture_guard
BEFORE UPDATE OR DELETE ON retail.r1e_qa_fixtures
FOR EACH ROW EXECUTE FUNCTION retail.r1e_fixture_guard();


CREATE TABLE retail.r1e_certification_policy(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  minimum_total_fixtures integer NOT NULL CHECK(minimum_total_fixtures>=100),
  minimum_duplicate_fixtures integer NOT NULL CHECK(minimum_duplicate_fixtures>=1000),
  minimum_decision_accuracy numeric NOT NULL CHECK(minimum_decision_accuracy BETWEEN 0 AND 100),
  maximum_false_positive_rate numeric NOT NULL CHECK(maximum_false_positive_rate BETWEEN 0 AND 100),
  minimum_duplicate_accuracy numeric NOT NULL CHECK(minimum_duplicate_accuracy BETWEEN 0 AND 100),
  minimum_evidence_coverage numeric NOT NULL CHECK(minimum_evidence_coverage BETWEEN 0 AND 100),
  minimum_explainability_coverage numeric NOT NULL CHECK(minimum_explainability_coverage BETWEEN 0 AND 100),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO retail.r1e_certification_policy(
  singleton,
  minimum_total_fixtures,
  minimum_duplicate_fixtures,
  minimum_decision_accuracy,
  maximum_false_positive_rate,
  minimum_duplicate_accuracy,
  minimum_evidence_coverage,
  minimum_explainability_coverage
)
VALUES(
  true,
  1200,
  1000,
  98.0,
  5.0,
  99.9,
  100.0,
  100.0
);

-- ---------- CERTIFICATION ----------------------------------------------------
CREATE TABLE retail.r1e_certification_runs(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  certification_version text NOT NULL,
  r1d_certification_run_id uuid NOT NULL REFERENCES retail.r1d_certification_runs(id) ON DELETE RESTRICT,
  r1d_package_sha256 text NOT NULL,
  r1e_package_sha256 text NOT NULL,
  ruleset_id uuid NOT NULL REFERENCES retail.r1e_match_rulesets(id) ON DELETE RESTRICT,
  ruleset_sha256 text NOT NULL,
  passive_results jsonb NOT NULL DEFAULT '[]'::jsonb,
  active_results jsonb NOT NULL DEFAULT '[]'::jsonb,
  replay_results jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence_manifest jsonb NOT NULL,
  evidence_manifest_text text NOT NULL,
  evidence_manifest_sha256 text NOT NULL,
  total_gates integer NOT NULL,
  passed_gates integer NOT NULL,
  failed_gates integer NOT NULL,
  certification_status text NOT NULL CHECK(certification_status IN('CERTIFIED','FAILED')),
  certified_by text NOT NULL,
  completed_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1e_certification_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1E certification records are append-only';
  END IF;
  IF NEW.evidence_manifest_sha256<>
     retail.r1e_sha256_text(NEW.evidence_manifest_text) THEN
    RAISE EXCEPTION 'R1E certification evidence SHA mismatch';
  END IF;
  IF NEW.evidence_manifest IS DISTINCT FROM NEW.evidence_manifest_text::jsonb THEN
    RAISE EXCEPTION 'R1E certification evidence JSON/text mismatch';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1e_certification_guard
BEFORE INSERT OR UPDATE OR DELETE ON retail.r1e_certification_runs
FOR EACH ROW EXECUTE FUNCTION retail.r1e_certification_guard();


CREATE OR REPLACE FUNCTION retail.r1e_history_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'R1E authority history is append-only';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1e_binding_history_guard
BEFORE UPDATE OR DELETE ON retail.r1e_r1d_binding_history
FOR EACH ROW EXECUTE FUNCTION retail.r1e_history_guard();


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
      AND cr.certification_version='r1e-v1.0.0'
      AND cr.ruleset_id=p_ruleset_id
      AND cr.ruleset_sha256=rs.rules_sha256
      AND rs.certification_status='certified'
      AND rs.rules_sha256=retail.r1e_sha256_jsonb(rs.rules_json)
      AND retail.r1e_r1d_binding_is_current()=true
    FROM retail.r1e_certification_runs cr
    JOIN retail.r1e_match_rulesets rs ON rs.id=cr.ruleset_id
    WHERE cr.id=(
      SELECT x.id
      FROM retail.r1e_certification_runs x
      WHERE x.completed_at IS NOT NULL
      ORDER BY x.completed_at DESC,x.id::text DESC
      LIMIT 1
    )
  ),false)
$$;

CREATE OR REPLACE VIEW retail.r1e_effective_qualified_products AS
SELECT
  q.*,
  rp.platform_product_key,
  rp.title,
  rp.brand,
  rp.model_number,
  rp.upc,
  rp.ean,
  rp.asin,
  rp.sku,
  rp.normalized_json
FROM retail.r1e_qualification_results q
JOIN retail.retail_products rp
  ON rp.id=q.retail_product_id
 AND rp.platform_id=q.platform_id
WHERE q.decision='QUALIFIED'
  AND retail.r1e_latest_certification_is_current(q.ruleset_id)=true
  AND q.evidence_sha256=retail.r1e_sha256_jsonb(q.evidence_json);

COMMENT ON VIEW retail.r1e_effective_qualified_products IS
'R1E sole downstream qualified-discovery authority. Visible only under current certified R1E release/ruleset; contains no profitability or purchase authority.';

-- ---------- AUDIT ------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail_audit.r1e_log_retail_change()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail_audit
AS $$
DECLARE
  v_row jsonb;
  v_actor text;
BEGIN
  v_row:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  v_actor:=COALESCE(
    NULLIF(current_setting('app.actor_name',true),''),
    NULLIF(current_setting('app.actor_id',true),''),
    session_user
  );

  INSERT INTO retail_audit.retail_change_log(
    schema_name,table_name,operation,row_pk,old_data,new_data,changed_by
  )
  VALUES(
    TG_TABLE_SCHEMA,TG_TABLE_NAME,TG_OP,COALESCE(v_row->>'id',''),
    CASE WHEN TG_OP IN('UPDATE','DELETE') THEN to_jsonb(OLD) END,
    CASE WHEN TG_OP IN('INSERT','UPDATE') THEN to_jsonb(NEW) END,
    v_actor
  );

  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER trg_r1e_audit_rulesets
AFTER INSERT OR UPDATE OR DELETE ON retail.r1e_match_rulesets
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1e_log_retail_change();

CREATE TRIGGER trg_r1e_audit_results
AFTER INSERT OR UPDATE OR DELETE ON retail.r1e_qualification_results
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1e_log_retail_change();

CREATE TRIGGER trg_r1e_audit_fixtures
AFTER INSERT OR UPDATE OR DELETE ON retail.r1e_qa_fixtures
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1e_log_retail_change();

CREATE TRIGGER trg_r1e_audit_binding
AFTER INSERT OR UPDATE OR DELETE ON retail.r1e_r1d_certification_binding
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1e_log_retail_change();

-- ---------- PRIVILEGES -------------------------------------------------------
REVOKE ALL ON FUNCTION retail.r1e_bind_r1d_certification(uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_certify_ruleset(uuid,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_validate_ruleset(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_evaluate_capture(uuid,uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1e_latest_certification_is_current(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION retail.r1e_evaluate_capture(uuid,uuid,uuid,text,text)
  TO retail_r1e_worker;
GRANT EXECUTE ON FUNCTION retail.r1e_bind_r1d_certification(uuid,uuid,text,text)
  TO retail_r1e_certifier;
GRANT EXECUTE ON FUNCTION retail.r1e_certify_ruleset(uuid,jsonb,text)
  TO retail_r1e_certifier;

GRANT SELECT ON retail.r1e_effective_qualified_products TO retail_r1e_reader;
GRANT SELECT ON retail.r1e_pending_captures TO retail_r1e_reader;
GRANT SELECT ON retail.r1e_qualification_results TO retail_r1e_reader;

REVOKE INSERT,UPDATE,DELETE ON retail.r1e_qualification_results FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE ON retail.r1e_r1d_certification_binding FROM PUBLIC;

COMMIT;
