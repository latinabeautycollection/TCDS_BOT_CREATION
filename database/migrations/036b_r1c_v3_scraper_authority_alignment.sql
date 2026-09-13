BEGIN;

-- ============================================================================
-- TCDS RETAIL R1C V3 — SCRAPER AUTHORITY ALIGNED FREEZE FINAL
--
-- Additive hardening over R1C V2.
-- Requires:
--   R1B core schema            = 3.0.0
--   R1B scraper hardening      = 4.0.0
--   latest R1B certification  = r1b-v4.0.0 / CERTIFIED
--
-- R1C remains deterministic compilation only.
-- ============================================================================

DO $$
DECLARE
  v_latest record;
BEGIN
  IF to_regclass('retail.r1c_schema_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1c_schema_state
       WHERE singleton=true AND schema_version='2.0.0'
     ) THEN
    RAISE EXCEPTION 'R1C V3 requires installed R1C V2 schema 2.0.0';
  END IF;

  IF to_regclass('retail.r1b_scraper_authority_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1b_scraper_authority_state
       WHERE singleton=true AND hardening_version='4.0.0'
     ) THEN
    RAISE EXCEPTION 'R1C V3 requires R1B scraper-authority hardening 4.0.0';
  END IF;

  IF to_regprocedure('retail.r1b_adapter_execution_ready(uuid)') IS NULL
     OR to_regprocedure('retail.r1b_assert_runtime_adapter(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'R1C V3 requires R1B V4 execution-ready/runtime authority functions';
  END IF;

  SELECT * INTO v_latest
  FROM retail.r1b_certification_runs
  WHERE completed_at IS NOT NULL
  ORDER BY completed_at DESC,id::text DESC
  LIMIT 1;

  IF NOT FOUND
     OR v_latest.certification_status<>'CERTIFIED'
     OR v_latest.certification_version<>'r1b-v4.0.0' THEN
    RAISE EXCEPTION
      'R1C V3 requires latest R1B certification = r1b-v4.0.0 CERTIFIED';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS retail.r1c_v3_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  hardening_version text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user,
  doctrine text NOT NULL
);

INSERT INTO retail.r1c_v3_state(singleton,hardening_version,doctrine)
VALUES(
  true,'3.0.0',
  'R1C compiles only current R1B V4 scraper-bound routes. Certified scraper contract requirements are minimum mandatory fields and cannot be weakened by compile profiles.'
)
ON CONFLICT(singleton) DO UPDATE SET
  hardening_version=EXCLUDED.hardening_version,
  doctrine=EXCLUDED.doctrine;


-- Compiler V3 columns must exist before SQL currentness functions are defined.
ALTER TABLE retail.search_compiler_versions
  ADD COLUMN IF NOT EXISTS hardening_migration_ref text,
  ADD COLUMN IF NOT EXISTS hardening_migration_sha256 text
    CHECK(hardening_migration_sha256 IS NULL OR hardening_migration_sha256 ~ '^[0-9a-f]{64}$'),
  ADD COLUMN IF NOT EXISTS query_builder_function_sha256 text
    CHECK(query_builder_function_sha256 IS NULL OR query_builder_function_sha256 ~ '^[0-9a-f]{64}$'),
  ADD COLUMN IF NOT EXISTS input_validator_function_sha256 text
    CHECK(input_validator_function_sha256 IS NULL OR input_validator_function_sha256 ~ '^[0-9a-f]{64}$'),
  ADD COLUMN IF NOT EXISTS scraper_authority_function_sha256 text
    CHECK(scraper_authority_function_sha256 IS NULL OR scraper_authority_function_sha256 ~ '^[0-9a-f]{64}$'),
  ADD COLUMN IF NOT EXISTS binding_current_function_sha256 text
    CHECK(binding_current_function_sha256 IS NULL OR binding_current_function_sha256 ~ '^[0-9a-f]{64}$'),
  ADD COLUMN IF NOT EXISTS profile_document_function_sha256 text
    CHECK(profile_document_function_sha256 IS NULL OR profile_document_function_sha256 ~ '^[0-9a-f]{64}$');

-- --------------------------------------------------------------------------
-- PGCRYPTO COMPATIBILITY
-- Avoid environment-specific search_path dependence.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1c_digest_sha256(p_bytes bytea)
RETURNS bytea
LANGUAGE plpgsql
IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
  v bytea;
BEGIN
  BEGIN
    EXECUTE 'SELECT extensions.digest($1,''sha256'')'
      INTO v USING p_bytes;
    RETURN v;
  EXCEPTION WHEN undefined_function OR invalid_schema_name THEN
    EXECUTE 'SELECT public.digest($1,''sha256'')'
      INTO v USING p_bytes;
    RETURN v;
  END;
END $$;

CREATE OR REPLACE FUNCTION retail.r1c_sha256_text(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT encode(retail.r1c_digest_sha256(convert_to(p_text,'UTF8')),'hex')
$$;

CREATE OR REPLACE FUNCTION retail.r1c_sha256_jsonb(p_doc jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT retail.r1c_sha256_text(p_doc::text) $$;

-- --------------------------------------------------------------------------
-- PROCESS REGISTRY
-- --------------------------------------------------------------------------
INSERT INTO arb.process_registry(
  process_name,phase_no,process_group,description,owner_team,active_flag
)
VALUES
('RETAIL_R1C_R1B_REBIND',2,'RETAIL_AUTOMATION',
 'Atomically bind/rebind R1C to the latest certified R1B V4 authority.',
 'TCDS Retail Automation',true),
('RETAIL_R1C_PROFILE_CREATE',2,'RETAIL_AUTOMATION',
 'Create a versioned immutable R1C compile profile from current R1B V4 route authority.',
 'TCDS Retail Automation',true),
('RETAIL_R1C_PROFILE_RETIRE',2,'RETAIL_AUTOMATION',
 'Retire a prior R1C compile profile version.',
 'TCDS Retail Automation',true)
ON CONFLICT(process_name) DO NOTHING;

-- --------------------------------------------------------------------------
-- GOVERNED R1B V4 BINDING / HISTORY
-- --------------------------------------------------------------------------
ALTER TABLE retail.r1c_r1b_certification_binding
  ADD COLUMN IF NOT EXISTS r1b_scraper_hardening_version text,
  ADD COLUMN IF NOT EXISTS r1b_certification_version text,
  ADD COLUMN IF NOT EXISTS source_process_run_id uuid
    REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS source_correlation_id text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE TABLE IF NOT EXISTS retail.r1c_r1b_binding_history(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  r1b_certification_run_id uuid NOT NULL
    REFERENCES retail.r1b_certification_runs(id) ON DELETE RESTRICT,
  r1b_schema_version text NOT NULL,
  r1b_scraper_hardening_version text NOT NULL,
  r1b_certification_version text NOT NULL,
  r1b_package_sha256 text NOT NULL,
  r1b_evidence_manifest_sha256 text NOT NULL,
  r1b_effective_routes_view_sha256 text NOT NULL,
  bound_by text NOT NULL,
  source_process_run_id uuid NOT NULL
    REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1c_bind_r1b_certification(
  p_r1b_certification_run_id uuid,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  cr record;
  v_view_sha text;
  v_latest uuid;
BEGIN
  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  SELECT id INTO v_latest
  FROM retail.r1b_certification_runs
  WHERE completed_at IS NOT NULL
  ORDER BY completed_at DESC,id::text DESC
  LIMIT 1;

  IF v_latest IS DISTINCT FROM p_r1b_certification_run_id THEN
    RAISE EXCEPTION 'R1C bind blocked: supplied R1B certification is not latest';
  END IF;

  SELECT * INTO cr
  FROM retail.r1b_certification_runs
  WHERE id=p_r1b_certification_run_id
    AND certification_status='CERTIFIED'
    AND certification_version='r1b-v4.0.0';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1C bind blocked: R1B V4 CERTIFIED run required';
  END IF;

  IF NOT EXISTS(
    SELECT 1 FROM retail.r1b_schema_state
    WHERE singleton=true AND schema_version='3.0.0'
  ) OR NOT EXISTS(
    SELECT 1 FROM retail.r1b_scraper_authority_state
    WHERE singleton=true AND hardening_version='4.0.0'
  ) THEN
    RAISE EXCEPTION 'R1C bind blocked: R1B schema/hardening identity mismatch';
  END IF;

  IF cr.package_sha256 IS NULL OR cr.package_sha256 !~ '^[0-9a-f]{64}$'
     OR cr.evidence_manifest_sha256 IS NULL
     OR cr.evidence_manifest_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R1C bind blocked: R1B package/evidence SHA missing or invalid';
  END IF;

  v_view_sha:=retail.r1c_sha256_text(
    pg_get_viewdef('retail.effective_search_routes'::regclass,true)
  );

  INSERT INTO retail.r1c_r1b_binding_history(
    r1b_certification_run_id,r1b_schema_version,
    r1b_scraper_hardening_version,r1b_certification_version,
    r1b_package_sha256,r1b_evidence_manifest_sha256,
    r1b_effective_routes_view_sha256,bound_by,
    source_process_run_id,source_correlation_id
  )
  VALUES(
    cr.id,'3.0.0','4.0.0','r1b-v4.0.0',
    cr.package_sha256,cr.evidence_manifest_sha256,
    v_view_sha,p_actor,p_process_run_id,p_correlation_id
  );

  INSERT INTO retail.r1c_r1b_certification_binding(
    singleton,r1b_schema_version,r1b_certification_run_id,
    r1b_package_sha256,r1b_evidence_manifest_sha256,
    r1b_effective_routes_view_sha256,bound_by,bound_at,
    r1b_scraper_hardening_version,r1b_certification_version,
    source_process_run_id,source_correlation_id,updated_at
  )
  VALUES(
    true,'3.0.0',cr.id,cr.package_sha256,
    cr.evidence_manifest_sha256,v_view_sha,p_actor,now(),
    '4.0.0','r1b-v4.0.0',
    p_process_run_id,p_correlation_id,now()
  )
  ON CONFLICT(singleton) DO UPDATE SET
    r1b_schema_version=EXCLUDED.r1b_schema_version,
    r1b_certification_run_id=EXCLUDED.r1b_certification_run_id,
    r1b_package_sha256=EXCLUDED.r1b_package_sha256,
    r1b_evidence_manifest_sha256=EXCLUDED.r1b_evidence_manifest_sha256,
    r1b_effective_routes_view_sha256=EXCLUDED.r1b_effective_routes_view_sha256,
    bound_by=EXCLUDED.bound_by,
    bound_at=EXCLUDED.bound_at,
    r1b_scraper_hardening_version=EXCLUDED.r1b_scraper_hardening_version,
    r1b_certification_version=EXCLUDED.r1b_certification_version,
    source_process_run_id=EXCLUDED.source_process_run_id,
    source_correlation_id=EXCLUDED.source_correlation_id,
    updated_at=now();
END $$;

CREATE OR REPLACE FUNCTION retail.r1c_r1b_binding_is_current()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      b.r1b_schema_version='3.0.0'
      AND b.r1b_scraper_hardening_version='4.0.0'
      AND b.r1b_certification_version='r1b-v4.0.0'
      AND s.schema_version='3.0.0'
      AND h.hardening_version='4.0.0'
      AND cr.id=b.r1b_certification_run_id
      AND cr.certification_status='CERTIFIED'
      AND cr.certification_version='r1b-v4.0.0'
      AND cr.id=(
        SELECT x.id
        FROM retail.r1b_certification_runs x
        WHERE x.completed_at IS NOT NULL
        ORDER BY x.completed_at DESC,x.id::text DESC
        LIMIT 1
      )
      AND cr.package_sha256=b.r1b_package_sha256
      AND cr.evidence_manifest_sha256=b.r1b_evidence_manifest_sha256
      AND b.r1b_effective_routes_view_sha256=
          retail.r1c_sha256_text(
            pg_get_viewdef('retail.effective_search_routes'::regclass,true)
          )
    FROM retail.r1c_r1b_certification_binding b
    JOIN retail.r1b_schema_state s ON s.singleton=true
    JOIN retail.r1b_scraper_authority_state h ON h.singleton=true
    JOIN retail.r1b_certification_runs cr ON cr.id=b.r1b_certification_run_id
    WHERE b.singleton=true
  ),false)
$$;

-- --------------------------------------------------------------------------
-- VERSIONED COMPILE PROFILES
-- --------------------------------------------------------------------------
ALTER TABLE retail.search_route_compile_profiles
  DROP CONSTRAINT IF EXISTS search_route_compile_profiles_route_id_key;

ALTER TABLE retail.search_route_compile_profiles
  ADD COLUMN IF NOT EXISTS profile_version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS contract_required_fields jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK(jsonb_typeof(contract_required_fields)='array'),
  ADD COLUMN IF NOT EXISTS effective_required_fields jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK(jsonb_typeof(effective_required_fields)='array'),
  ADD COLUMN IF NOT EXISTS source_process_run_id uuid
    REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS source_correlation_id text;

CREATE UNIQUE INDEX IF NOT EXISTS uq_r1c_profile_route_version
ON retail.search_route_compile_profiles(route_id,profile_version);

CREATE UNIQUE INDEX IF NOT EXISTS uq_r1c_one_active_profile_per_route
ON retail.search_route_compile_profiles(route_id)
WHERE profile_status='active';

CREATE OR REPLACE FUNCTION retail.r1c_jsonb_text_union(
  p_a jsonb,
  p_b jsonb
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $$
  SELECT COALESCE(
    jsonb_agg(v ORDER BY v),
    '[]'::jsonb
  )
  FROM (
    SELECT DISTINCT value v
    FROM (
      SELECT jsonb_array_elements_text(COALESCE(p_a,'[]'::jsonb)) value
      UNION ALL
      SELECT jsonb_array_elements_text(COALESCE(p_b,'[]'::jsonb)) value
    ) u
  ) d
$$;

CREATE OR REPLACE FUNCTION retail.r1c_compile_profile_document(
  p_row retail.search_route_compile_profiles
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'route_id',p_row.route_id,
    'route_authority_hash',p_row.route_authority_hash,
    'profile_version',p_row.profile_version,
    'compile_mode',p_row.compile_mode,
    'contract_required_fields',p_row.contract_required_fields,
    'additional_required_fields',p_row.required_fields,
    'effective_required_fields',p_row.effective_required_fields,
    'query_policy',p_row.query_policy
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1c_compile_profile_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1C compile profiles cannot be deleted; retire them';
  END IF;

  IF TG_OP='INSERT' THEN
    NEW.effective_required_fields:=
      retail.r1c_jsonb_text_union(
        NEW.contract_required_fields,
        NEW.required_fields
      );

    IF NEW.compile_mode='store_inventory'
       AND NOT (NEW.effective_required_fields ? 'store_id') THEN
      RAISE EXCEPTION 'store_inventory profile must require store_id';
    END IF;

    NEW.profile_sha256:=
      retail.r1c_sha256_jsonb(
        retail.r1c_compile_profile_document(NEW)
      );
    RETURN NEW;
  END IF;

  IF (to_jsonb(NEW)-ARRAY['profile_status'])
     IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['profile_status']) THEN
    RAISE EXCEPTION
      'R1C compile profile content is immutable; create a new profile_version';
  END IF;

  IF OLD.profile_status='retired'
     AND NEW.profile_status<>'retired' THEN
    RAISE EXCEPTION 'Retired compile profile is terminal';
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1c_compile_profile_guard
ON retail.search_route_compile_profiles;
CREATE TRIGGER trg_r1c_compile_profile_guard
BEFORE INSERT OR UPDATE OR DELETE ON retail.search_route_compile_profiles
FOR EACH ROW EXECUTE FUNCTION retail.r1c_compile_profile_guard();

-- --------------------------------------------------------------------------
-- INPUT CONTRACT: R1B V4 TRANSPORTS / REQUIRED FIELDS
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1c_validate_input_contract(
  p_contract jsonb,
  p_compile_mode text,
  p_effective_required_fields jsonb
)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_transport text;
  v_field text;
  v_mode_field text;
  v_allowed_fields constant text[] := ARRAY[
    'query','category','product_url','store_id',
    'postal_code','region','result_limit'
  ];
BEGIN
  IF p_contract IS NULL OR jsonb_typeof(p_contract)<>'object' THEN
    RAISE EXCEPTION 'Input contract must be a JSON object';
  END IF;

  v_transport:=NULLIF(p_contract->>'transport','');
  IF v_transport IS NULL
     OR v_transport NOT IN ('env','argv','json','query','hybrid') THEN
    RAISE EXCEPTION 'Unsupported or missing input contract transport %',
      v_transport;
  END IF;

  IF NOT (p_contract ? 'compile_modes')
     OR jsonb_typeof(p_contract->'compile_modes')<>'array'
     OR jsonb_array_length(p_contract->'compile_modes')=0 THEN
    RAISE EXCEPTION 'compile_modes must be a non-empty array';
  END IF;

  IF COALESCE((p_contract->'compile_modes') ? p_compile_mode,false)
     IS NOT TRUE THEN
    RAISE EXCEPTION 'Compile mode % not certified by input contract',
      p_compile_mode;
  END IF;

  IF NOT (p_contract ? 'field_map')
     OR jsonb_typeof(p_contract->'field_map')<>'object'
     OR jsonb_object_length(p_contract->'field_map')=0 THEN
    RAISE EXCEPTION 'field_map must be a non-empty object';
  END IF;

  IF p_effective_required_fields IS NULL
     OR jsonb_typeof(p_effective_required_fields)<>'array' THEN
    RAISE EXCEPTION 'effective_required_fields must be an array';
  END IF;

  FOR v_field IN SELECT key FROM jsonb_each(p_contract->'field_map')
  LOOP
    IF NOT (v_field=ANY(v_allowed_fields)) THEN
      RAISE EXCEPTION 'Unknown canonical field in field_map: %',v_field;
    END IF;
    IF NULLIF(p_contract#>>ARRAY['field_map',v_field],'') IS NULL THEN
      RAISE EXCEPTION 'Empty target mapping for canonical field %',v_field;
    END IF;
  END LOOP;

  FOR v_field IN
    SELECT jsonb_array_elements_text(p_effective_required_fields)
  LOOP
    IF NOT (v_field=ANY(v_allowed_fields)) THEN
      RAISE EXCEPTION 'Unknown required canonical field %',v_field;
    END IF;
    IF NULLIF(p_contract#>>ARRAY['field_map',v_field],'') IS NULL THEN
      RAISE EXCEPTION 'Required field % lacks certified mapping',v_field;
    END IF;
  END LOOP;

  v_mode_field:=CASE p_compile_mode
    WHEN 'keyword' THEN 'query'
    WHEN 'category' THEN 'category'
    WHEN 'product_url' THEN 'product_url'
    WHEN 'store_inventory' THEN 'store_id'
    ELSE NULL
  END;

  IF v_mode_field IS NULL THEN
    RAISE EXCEPTION 'Unknown compile mode %',p_compile_mode;
  END IF;

  IF NULLIF(p_contract#>>ARRAY['field_map',v_mode_field],'') IS NULL THEN
    RAISE EXCEPTION 'Compile mode % requires field_map.%',
      p_compile_mode,v_mode_field;
  END IF;

  IF EXISTS(
    SELECT 1
    FROM (
      SELECT value,count(*) n
      FROM jsonb_each_text(p_contract->'field_map')
      GROUP BY value
      HAVING count(*)>1
    ) d
  ) THEN
    RAISE EXCEPTION
      'Input contract maps multiple canonical fields to same adapter field';
  END IF;

  IF p_contract ? 'keyword_env'
     OR p_contract ? 'store_id_env'
     OR p_contract ? 'postal_code_env'
     OR p_contract ? 'region_env'
     OR p_contract ? 'result_limit_env' THEN
    RAISE EXCEPTION
      'Legacy *_env mappings prohibited; use canonical field_map';
  END IF;
END $$;

-- --------------------------------------------------------------------------
-- QUERY POLICY IMPLEMENTATION
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1c_build_query_v3(
  p_brand text,
  p_model_family text,
  p_terms jsonb,
  p_query_policy jsonb
)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_dedupe text:=COALESCE(p_query_policy->>'dedupe','token_case_insensitive');
  v_stable boolean:=COALESCE((p_query_policy->>'stable_order')::boolean,true);
  v_tokens text[]:=ARRAY[]::text[];
  v_out text[]:=ARRAY[]::text[];
  v_term text;
  v_token text;
  v_seen text[]:=ARRAY[]::text[];
BEGIN
  IF v_dedupe NOT IN ('token_case_insensitive','phrase_case_insensitive') THEN
    RAISE EXCEPTION 'Unsupported query dedupe policy %',v_dedupe;
  END IF;

  IF v_dedupe='phrase_case_insensitive' THEN
    RETURN retail.r1c_build_query(p_brand,p_model_family,p_terms);
  END IF;

  -- Token-level case-insensitive dedupe, stable first occurrence.
  FOREACH v_term IN ARRAY ARRAY[
    NULLIF(btrim(p_brand),''),
    NULLIF(btrim(p_model_family),'')
  ]
  LOOP
    IF v_term IS NULL THEN CONTINUE; END IF;
    FOREACH v_token IN ARRAY regexp_split_to_array(
      regexp_replace(v_term,'\s+',' ','g'),'\s+'
    )
    LOOP
      IF lower(v_token)<>ALL(v_seen) THEN
        v_seen:=array_append(v_seen,lower(v_token));
        v_out:=array_append(v_out,v_token);
      END IF;
    END LOOP;
  END LOOP;

  FOR v_term IN
    SELECT value
    FROM jsonb_array_elements_text(COALESCE(p_terms,'[]'::jsonb))
    WITH ORDINALITY q(value,ord)
    ORDER BY ord
  LOOP
    FOREACH v_token IN ARRAY regexp_split_to_array(
      regexp_replace(btrim(v_term),'\s+',' ','g'),'\s+'
    )
    LOOP
      IF lower(v_token)<>ALL(v_seen) THEN
        v_seen:=array_append(v_seen,lower(v_token));
        v_out:=array_append(v_out,v_token);
      END IF;
    END LOOP;
  END LOOP;

  IF v_stable IS NOT TRUE THEN
    SELECT array_agg(x ORDER BY lower(x),x)
      INTO v_out
    FROM unnest(v_out) x;
  END IF;

  RETURN NULLIF(array_to_string(v_out,' '),'');
END $$;

-- --------------------------------------------------------------------------
-- SCRAPER AUTHORITY EVIDENCE
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1c_scraper_authority_document(
  p_adapter_id uuid
)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT jsonb_build_object(
    'adapter_id',a.id,
    'scraper_asset_id',s.id,
    'implementation_authority_type',s.implementation_authority_type,
    'implementation_root',s.implementation_root,
    'package_tree_sha256',s.package_tree_sha256,
    'entrypoint_sha256',s.entrypoint_sha256,
    'verification_evidence_sha256',s.verification_evidence_sha256,
    'scraper_contract_id',c.id,
    'scraper_contract_version',c.contract_version,
    'scraper_contract_sha256',c.contract_sha256,
    'interface_evidence_sha256',c.interface_evidence_sha256,
    'contract_required_fields',c.required_fields,
    'contract_status',c.certification_status,
    'execution_ready',retail.r1b_adapter_execution_ready(a.id)
  )
  FROM retail.retail_search_adapters a
  JOIN retail.retail_scraper_assets s ON s.id=a.scraper_asset_id
  JOIN retail.retail_scraper_contracts c ON c.id=a.scraper_contract_id
  WHERE a.id=p_adapter_id
$$;

-- --------------------------------------------------------------------------
-- PROFILE CREATION: CONTRACT FIELDS ARE MINIMUM, PROFILE MAY ONLY ADD
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1c_create_compile_profile(
  p_route_id uuid,
  p_compile_mode text,
  p_additional_required_fields jsonb,
  p_query_policy jsonb,
  p_actor text,
  p_process_run_id uuid DEFAULT NULL,
  p_correlation_id text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  r record;
  c record;
  v_id uuid;
  v_version integer;
  v_contract_required jsonb;
  v_effective jsonb;
  v_policy jsonb;
BEGIN
  PERFORM set_config('app.actor_type','service_account',true);
  PERFORM set_config('app.actor_id',p_actor,true);
  PERFORM set_config('app.actor_name',p_actor,true);
  IF p_process_run_id IS NOT NULL THEN
    PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  END IF;
  IF p_correlation_id IS NOT NULL THEN
    PERFORM set_config('app.correlation_id',p_correlation_id,true);
  END IF;

  IF retail.r1c_r1b_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'Compile profile creation blocked: R1B V4 binding not current';
  END IF;

  SELECT * INTO r
  FROM retail.effective_search_routes
  WHERE route_id=p_route_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Compile profile creation blocked: route not effective';
  END IF;

  IF retail.r1b_adapter_execution_ready(r.adapter_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Compile profile creation blocked: adapter not execution-ready';
  END IF;

  SELECT * INTO c
  FROM retail.retail_scraper_contracts
  WHERE id=(
    SELECT scraper_contract_id
    FROM retail.retail_search_adapters
    WHERE id=r.adapter_id
  )
    AND certification_status='certified_for_r1';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Compile profile creation blocked: certified scraper contract missing';
  END IF;

  v_contract_required:=c.required_fields;
  v_effective:=retail.r1c_jsonb_text_union(
    v_contract_required,
    COALESCE(p_additional_required_fields,'[]'::jsonb)
  );

  v_policy:=COALESCE(
    p_query_policy,
    jsonb_build_object(
      'dedupe','token_case_insensitive',
      'stable_order',true
    )
  );

  PERFORM retail.r1c_validate_input_contract(
    r.input_contract_json,p_compile_mode,v_effective
  );

  IF p_compile_mode='keyword'
     AND r.supports_keyword_search IS NOT TRUE THEN
    RAISE EXCEPTION 'Adapter does not support keyword mode';
  ELSIF p_compile_mode='category'
     AND r.supports_category_search IS NOT TRUE THEN
    RAISE EXCEPTION 'Adapter does not support category mode';
  ELSIF p_compile_mode='product_url'
     AND r.supports_product_url IS NOT TRUE THEN
    RAISE EXCEPTION 'Adapter does not support product_url mode';
  ELSIF p_compile_mode='store_inventory'
     AND r.supports_store_id IS NOT TRUE THEN
    RAISE EXCEPTION 'Adapter does not support store_inventory mode';
  END IF;

  IF v_effective ? 'store_id'
     AND r.supports_store_id IS NOT TRUE THEN
    RAISE EXCEPTION 'Required store_id not supported';
  END IF;
  IF v_effective ? 'postal_code'
     AND r.supports_postal_code IS NOT TRUE THEN
    RAISE EXCEPTION 'Required postal_code not supported';
  END IF;
  IF v_effective ? 'region'
     AND r.supports_region IS NOT TRUE THEN
    RAISE EXCEPTION 'Required region not supported';
  END IF;
  IF v_effective ? 'result_limit'
     AND r.supports_result_limit IS NOT TRUE THEN
    RAISE EXCEPTION 'Required result_limit not supported';
  END IF;

  UPDATE retail.search_route_compile_profiles
  SET profile_status='retired'
  WHERE route_id=p_route_id AND profile_status='active';

  SELECT COALESCE(max(profile_version),0)+1
    INTO v_version
  FROM retail.search_route_compile_profiles
  WHERE route_id=p_route_id;

  INSERT INTO retail.search_route_compile_profiles(
    route_id,route_authority_hash,profile_version,
    compile_mode,required_fields,contract_required_fields,
    effective_required_fields,query_policy,
    profile_sha256,created_by,
    source_process_run_id,source_correlation_id
  )
  VALUES(
    r.route_id,r.route_authority_hash,v_version,
    p_compile_mode,
    COALESCE(p_additional_required_fields,'[]'::jsonb),
    v_contract_required,v_effective,v_policy,
    repeat('0',64),p_actor,
    p_process_run_id,p_correlation_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

-- --------------------------------------------------------------------------
-- NORMALIZED JOB + PAYLOAD V3
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1c_normalized_job_document(
  p_route_id uuid,
  p_profile_id uuid
)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT jsonb_build_object(
    'schema_version','r1c-normalized-job-v3',
    'route_id',r.route_id,
    'route_authority_hash',r.route_authority_hash,
    'compile_profile',jsonb_build_object(
      'profile_id',p.id,
      'profile_version',p.profile_version,
      'profile_sha256',p.profile_sha256,
      'compile_mode',p.compile_mode,
      'contract_required_fields',p.contract_required_fields,
      'additional_required_fields',p.required_fields,
      'effective_required_fields',p.effective_required_fields,
      'query_policy',p.query_policy
    ),
    'target',jsonb_build_object(
      'target_id',r.target_id,
      'target_code',r.target_code,
      'r1a_revision_id',r.r1a_revision_id,
      'r1a_revision_hash',r.r1a_revision_hash,
      'category_key',r.category_key,
      'family_key',r.family_key,
      'family_name',r.family_name,
      'canonical_product_key',r.canonical_product_key,
      'brand',r.brand,
      'model_family',r.model_family,
      'include_terms',r.include_terms,
      'exclude_terms',r.exclude_terms,
      'allowed_product_conditions',r.allowed_product_conditions,
      'desired_discount_signals',r.desired_discount_signals,
      'discovery_price_ceiling_usd',r.discovery_price_ceiling_usd,
      'discovery_result_limit',r.discovery_result_limit,
      'priority_tier',r.priority_tier
    ),
    'platform',jsonb_build_object(
      'platform_id',r.platform_id,
      'platform_code',r.platform_code,
      'platform_name',r.platform_name,
      'base_url',r.base_url
    ),
    'source',jsonb_build_object(
      'collection_source_id',r.collection_source_id,
      'source_code',r.source_code,
      'source_name',r.source_name,
      'source_url',r.source_url,
      'source_type',r.source_type,
      'source_scope',r.source_scope,
      'collection_method',r.collection_method,
      'dataset_id',r.dataset_id,
      'unlocker_zone',r.unlocker_zone,
      'request_overrides',r.request_overrides,
      'pagination_policy',r.pagination_policy,
      'qualification_policy',r.qualification_policy
    ),
    'adapter',jsonb_build_object(
      'adapter_id',r.adapter_id,
      'adapter_code',r.adapter_code,
      'adapter_version',r.adapter_version,
      'implementation_ref',r.implementation_ref,
      'implementation_sha256',r.implementation_sha256,
      'input_contract_sha256',r.input_contract_sha256,
      'capability_sha256',r.capability_sha256,
      'certification_fingerprint_hash',r.certification_fingerprint_hash
    ),
    'scraper_authority',
      retail.r1c_scraper_authority_document(r.adapter_id),
    'location',CASE WHEN r.location_id IS NULL THEN NULL ELSE jsonb_build_object(
      'location_id',r.location_id,
      'location_code',r.location_code,
      'location_type',r.location_type,
      'country_code',r.country_code,
      'state_code',r.state_code,
      'metro_name',r.metro_name,
      'postal_code',r.postal_code,
      'retailer_store_id',r.retailer_store_id,
      'display_name',r.display_name
    ) END
  )
  FROM retail.effective_search_routes r
  JOIN retail.search_route_compile_profiles p ON p.id=p_profile_id
  WHERE r.route_id=p_route_id
    AND p.route_id=r.route_id
    AND p.route_authority_hash=r.route_authority_hash
    AND p.profile_status='active'
    AND p.profile_sha256=
      retail.r1c_sha256_jsonb(retail.r1c_compile_profile_document(p))
    AND retail.r1b_adapter_execution_ready(r.adapter_id)=true
$$;

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
  p record;
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

-- --------------------------------------------------------------------------
-- COMPILE EVIDENCE EXPLICITLY BINDS SCRAPER ASSET / CONTRACT
-- --------------------------------------------------------------------------
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
  c record;
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

CREATE OR REPLACE FUNCTION retail.r1c_compilation_is_current(
  p_compilation_id uuid
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      j.compilation_status='compiled'
      AND retail.r1c_r1b_binding_is_current()=true
      AND retail.r1b_adapter_execution_ready(j.adapter_id)=true
      AND r.route_authority_hash=j.route_authority_hash
      AND p.profile_status='active'
      AND p.profile_sha256=j.compile_profile_sha256
      AND p.profile_sha256=
          retail.r1c_sha256_jsonb(
            retail.r1c_compile_profile_document(p)
          )
      AND p.contract_required_fields IS NOT DISTINCT FROM
          COALESCE(r.input_contract_json->'required_fields','[]'::jsonb)
      AND c.certification_status='certified'
      AND c.compiler_authority_sha256=j.compiler_authority_sha256
      AND c.compiler_authority_sha256=
          retail.r1c_sha256_jsonb(
            retail.r1c_compiler_authority_document(c)
          )
      AND c.query_builder_function_sha256=
          retail.r1c_function_sha256(
            'retail.r1c_build_query_v3(text,text,jsonb,jsonb)'::regprocedure
          )
      AND c.input_validator_function_sha256=
          retail.r1c_function_sha256(
            'retail.r1c_validate_input_contract(jsonb,text,jsonb)'::regprocedure
          )
      AND c.scraper_authority_function_sha256=
          retail.r1c_function_sha256(
            'retail.r1c_scraper_authority_document(uuid)'::regprocedure
          )
      AND c.binding_current_function_sha256=
          retail.r1c_function_sha256(
            'retail.r1c_r1b_binding_is_current()'::regprocedure
          )
      AND c.profile_document_function_sha256=
          retail.r1c_function_sha256(
            'retail.r1c_compile_profile_document(retail.search_route_compile_profiles)'::regprocedure
          )
      AND c.normalized_job_function_sha256=
          retail.r1c_function_sha256(
            'retail.r1c_normalized_job_document(uuid,uuid)'::regprocedure
          )
      AND c.adapter_payload_function_sha256=
          retail.r1c_function_sha256(
            'retail.r1c_adapter_payload_document(uuid,uuid)'::regprocedure
          )
      AND c.compile_route_function_sha256=
          retail.r1c_function_sha256(
            'retail.r1c_compile_route(uuid,uuid,uuid,uuid,text,text)'::regprocedure
          )
      AND c.currentness_function_sha256=
          retail.r1c_function_sha256(
            'retail.r1c_compilation_is_current(uuid)'::regprocedure
          )
      AND j.normalized_job_sha256=
          retail.r1c_sha256_jsonb(j.normalized_job_json)
      AND j.adapter_payload_sha256=
          retail.r1c_sha256_jsonb(j.adapter_payload_json)
      AND j.compilation_evidence_sha256=
          retail.r1c_sha256_jsonb(j.compilation_evidence_json)
      AND j.compilation_evidence_json->'scraper_authority'=
          retail.r1c_scraper_authority_document(j.adapter_id)
    FROM retail.search_job_compilations j
    JOIN retail.effective_search_routes r ON r.route_id=j.route_id
    JOIN retail.search_route_compile_profiles p
      ON p.id=j.compile_profile_id
    JOIN retail.search_compiler_versions c
      ON c.id=j.compiler_version_id
    WHERE j.id=p_compilation_id
  ),false)
$$;

CREATE OR REPLACE VIEW retail.effective_compiled_search_jobs AS
SELECT j.*
FROM retail.search_job_compilations j
WHERE retail.r1c_compilation_is_current(j.id)=true;

COMMENT ON VIEW retail.effective_compiled_search_jobs IS
'R1C V3 sole R1D input. R1D must runtime-attest R1B V4 scraper artifact/package, R1C compiler authority and current certified R1C release before dispatch.';

-- --------------------------------------------------------------------------
-- R1C CERTIFICATION MUST BIND R1B V4
-- --------------------------------------------------------------------------
ALTER TABLE retail.r1c_certification_runs
  ADD COLUMN IF NOT EXISTS r1b_certification_version text,
  ADD COLUMN IF NOT EXISTS r1b_scraper_hardening_version text;

CREATE OR REPLACE FUNCTION retail.r1c_latest_certification_is_current(
  p_compiler_version_id uuid
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      cr.certification_status='CERTIFIED'
      AND cr.certification_version='r1c-v3.0.0'
      AND cr.compiler_version_id=p_compiler_version_id
      AND cr.compiler_authority_sha256=c.compiler_authority_sha256
      AND cr.r1b_certification_version='r1b-v4.0.0'
      AND cr.r1b_scraper_hardening_version='4.0.0'
      AND retail.r1c_r1b_binding_is_current()=true
    FROM retail.r1c_certification_runs cr
    JOIN retail.search_compiler_versions c
      ON c.id=cr.compiler_version_id
    WHERE cr.id=(
      SELECT x.id
      FROM retail.r1c_certification_runs x
      WHERE x.completed_at IS NOT NULL
      ORDER BY x.completed_at DESC,x.id::text DESC
      LIMIT 1
    )
  ),false)
$$;

-- --------------------------------------------------------------------------
-- PRIVILEGE HARDENING
-- --------------------------------------------------------------------------
REVOKE ALL ON FUNCTION retail.r1c_bind_r1b_certification(
  uuid,uuid,text,text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1c_scraper_authority_document(uuid)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1c_create_compile_profile(
  uuid,text,jsonb,jsonb,text,uuid,text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION retail.r1c_bind_r1b_certification(
  uuid,uuid,text,text
) TO retail_r1c_certifier;
GRANT EXECUTE ON FUNCTION retail.r1c_create_compile_profile(
  uuid,text,jsonb,jsonb,text,uuid,text
) TO retail_r1c_compiler;


-- --------------------------------------------------------------------------
-- COMPILER V3 RELEASE IDENTITY
-- --------------------------------------------------------------------------
ALTER TABLE retail.search_compiler_versions
  ADD COLUMN IF NOT EXISTS hardening_migration_ref text,
  ADD COLUMN IF NOT EXISTS hardening_migration_sha256 text
    CHECK(hardening_migration_sha256 IS NULL OR hardening_migration_sha256 ~ '^[0-9a-f]{64}$');

CREATE OR REPLACE FUNCTION retail.r1c_compiler_authority_document(
  p_row retail.search_compiler_versions
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'compiler_code',p_row.compiler_code,
    'compiler_version',p_row.compiler_version,
    'typescript_wrapper_sha256',p_row.typescript_wrapper_sha256,
    'sql_migration_sha256',p_row.sql_migration_sha256,
    'hardening_migration_sha256',p_row.hardening_migration_sha256,
    'normalized_job_function_sha256',p_row.normalized_job_function_sha256,
    'adapter_payload_function_sha256',p_row.adapter_payload_function_sha256,
    'compile_route_function_sha256',p_row.compile_route_function_sha256,
    'currentness_function_sha256',p_row.currentness_function_sha256,
    'compiler_contract_sha256',p_row.compiler_contract_sha256,
    'qa_evidence_sha256',p_row.qa_evidence_sha256
  )
$$;

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
  c record;
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

REVOKE ALL ON FUNCTION retail.r1c_assert_runtime_compiler_v3(
  uuid,text,text,text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION retail.r1c_assert_runtime_compiler_v3(
  uuid,text,text,text
) TO retail_r1c_compiler;


-- --------------------------------------------------------------------------
-- BINDING AUDIT / DIRECT DML RESTRICTION
-- --------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_r1c_audit_r1b_binding
ON retail.r1c_r1b_certification_binding;
CREATE TRIGGER trg_r1c_audit_r1b_binding
AFTER INSERT OR UPDATE OR DELETE
ON retail.r1c_r1b_certification_binding
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1c_log_retail_change();

REVOKE INSERT,UPDATE,DELETE
ON retail.r1c_r1b_certification_binding FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE
ON retail.r1c_r1b_binding_history FROM PUBLIC;


-- --------------------------------------------------------------------------
-- FULL V3 HELPER FUNCTION ATTESTATION
-- --------------------------------------------------------------------------
ALTER TABLE retail.search_compiler_versions
  ADD COLUMN IF NOT EXISTS query_builder_function_sha256 text
    CHECK(query_builder_function_sha256 IS NULL OR query_builder_function_sha256 ~ '^[0-9a-f]{64}$'),
  ADD COLUMN IF NOT EXISTS input_validator_function_sha256 text
    CHECK(input_validator_function_sha256 IS NULL OR input_validator_function_sha256 ~ '^[0-9a-f]{64}$'),
  ADD COLUMN IF NOT EXISTS scraper_authority_function_sha256 text
    CHECK(scraper_authority_function_sha256 IS NULL OR scraper_authority_function_sha256 ~ '^[0-9a-f]{64}$'),
  ADD COLUMN IF NOT EXISTS binding_current_function_sha256 text
    CHECK(binding_current_function_sha256 IS NULL OR binding_current_function_sha256 ~ '^[0-9a-f]{64}$'),
  ADD COLUMN IF NOT EXISTS profile_document_function_sha256 text
    CHECK(profile_document_function_sha256 IS NULL OR profile_document_function_sha256 ~ '^[0-9a-f]{64}$');

CREATE OR REPLACE FUNCTION retail.r1c_compiler_authority_document(
  p_row retail.search_compiler_versions
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'compiler_code',p_row.compiler_code,
    'compiler_version',p_row.compiler_version,
    'typescript_wrapper_sha256',p_row.typescript_wrapper_sha256,
    'sql_migration_sha256',p_row.sql_migration_sha256,
    'hardening_migration_sha256',p_row.hardening_migration_sha256,
    'normalized_job_function_sha256',p_row.normalized_job_function_sha256,
    'adapter_payload_function_sha256',p_row.adapter_payload_function_sha256,
    'compile_route_function_sha256',p_row.compile_route_function_sha256,
    'currentness_function_sha256',p_row.currentness_function_sha256,
    'query_builder_function_sha256',p_row.query_builder_function_sha256,
    'input_validator_function_sha256',p_row.input_validator_function_sha256,
    'scraper_authority_function_sha256',p_row.scraper_authority_function_sha256,
    'binding_current_function_sha256',p_row.binding_current_function_sha256,
    'profile_document_function_sha256',p_row.profile_document_function_sha256,
    'compiler_contract_sha256',p_row.compiler_contract_sha256,
    'qa_evidence_sha256',p_row.qa_evidence_sha256
  )
$$;

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
  c record;
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

CREATE OR REPLACE FUNCTION retail.r1c_compiler_functions_current(
  p_compiler_id uuid
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      c.normalized_job_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_normalized_job_document(uuid,uuid)'::regprocedure
        )
      AND c.adapter_payload_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_adapter_payload_document(uuid,uuid)'::regprocedure
        )
      AND c.compile_route_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_compile_route(uuid,uuid,uuid,uuid,text,text)'::regprocedure
        )
      AND c.currentness_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_compilation_is_current(uuid)'::regprocedure
        )
      AND c.query_builder_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_build_query_v3(text,text,jsonb,jsonb)'::regprocedure
        )
      AND c.input_validator_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_validate_input_contract(jsonb,text,jsonb)'::regprocedure
        )
      AND c.scraper_authority_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_scraper_authority_document(uuid)'::regprocedure
        )
      AND c.binding_current_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_r1b_binding_is_current()'::regprocedure
        )
      AND c.profile_document_function_sha256=
        retail.r1c_function_sha256(
          'retail.r1c_compile_profile_document(retail.search_route_compile_profiles)'::regprocedure
        )
    FROM retail.search_compiler_versions c
    WHERE c.id=p_compiler_id
  ),false)
$$;

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
  c record;
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

REVOKE ALL ON FUNCTION retail.r1c_compiler_functions_current(uuid)
FROM PUBLIC;


REVOKE INSERT,UPDATE,DELETE
ON retail.search_route_compile_profiles FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_r1c_audit_r1b_binding_history
ON retail.r1c_r1b_binding_history;
CREATE TRIGGER trg_r1c_audit_r1b_binding_history
AFTER INSERT OR UPDATE OR DELETE
ON retail.r1c_r1b_binding_history
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1c_log_retail_change();

COMMIT;
