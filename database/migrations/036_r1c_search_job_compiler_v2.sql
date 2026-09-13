BEGIN;

CREATE SCHEMA IF NOT EXISTS retail;
CREATE SCHEMA IF NOT EXISTS retail_audit;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================================
-- TCDS RETAIL R1C — DETERMINISTIC SEARCH JOB COMPILER
-- GREEN TIER 1 HARDENED V2 FREEZE HARDENED FINAL
--
-- R1C owns deterministic compilation only.
-- R1A owns WHAT to search.
-- R1B owns WHERE / THROUGH WHICH CERTIFIED RETAIL PATH.
-- R1D will own scheduling, budget, leasing and dispatch.
-- ============================================================================

-- ---------- PRE-FLIGHT / RETRY SAFETY ---------------------------------------
DO $$
DECLARE
  v_version text;
BEGIN
  IF to_regclass('retail.r1c_schema_state') IS NULL THEN
    IF to_regclass('retail.search_job_compilations') IS NOT NULL
       OR to_regclass('retail.search_compiler_versions') IS NOT NULL
       OR to_regclass('retail.effective_compiled_search_jobs') IS NOT NULL THEN
      RAISE EXCEPTION
        'R1C V2 preflight failed: partial/unknown R1C objects exist without schema marker';
    END IF;
  ELSE
    SELECT schema_version INTO v_version
    FROM retail.r1c_schema_state WHERE singleton=true;

    IF v_version IS DISTINCT FROM '2.0.0' THEN
      RAISE EXCEPTION
        'R1C V2 preflight failed: existing R1C schema version % is incompatible', v_version;
    END IF;

    -- Exact V2 is a safe idempotent re-run. Remaining DDL uses IF NOT EXISTS,
    -- CREATE OR REPLACE, and DROP/CREATE trigger patterns.
  END IF;

  IF to_regclass('retail.effective_search_routes') IS NULL
     OR to_regclass('retail.r1b_schema_state') IS NULL
     OR to_regclass('retail.r1b_certification_runs') IS NULL THEN
    RAISE EXCEPTION 'R1C V2 requires R1B V3 authority and certification tables';
  END IF;

  IF NOT EXISTS(
    SELECT 1 FROM retail.r1b_schema_state
    WHERE singleton=true AND schema_version='3.0.0'
  ) THEN
    RAISE EXCEPTION 'R1C V2 requires exact R1B schema version 3.0.0';
  END IF;

  IF NOT EXISTS(
    SELECT 1 FROM retail.r1b_certification_runs
    WHERE certification_status='CERTIFIED'
  ) THEN
    RAISE EXCEPTION 'R1C V2 requires at least one CERTIFIED R1B certification run';
  END IF;

  IF to_regclass('arb.process_registry') IS NULL
     OR to_regclass('arb.process_runs') IS NULL
     OR to_regclass('retail_audit.retail_change_log') IS NULL THEN
    RAISE EXCEPTION 'R1C V2 provenance/audit dependencies missing';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS retail.r1c_schema_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  schema_version text NOT NULL,
  ownership_doctrine text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user
);

INSERT INTO retail.r1c_schema_state(singleton,schema_version,ownership_doctrine)
VALUES(
  true,'2.0.0',
  'R1C deterministically compiles exact certified R1B routes. No schedule, budget, dispatch, purchase or checkout authority.'
)
ON CONFLICT(singleton) DO NOTHING;

-- ---------- RBAC FAMILIES ---------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1c_reader') THEN
    CREATE ROLE retail_r1c_reader NOLOGIN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1c_compiler') THEN
    CREATE ROLE retail_r1c_compiler NOLOGIN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1c_certifier') THEN
    CREATE ROLE retail_r1c_certifier NOLOGIN;
  END IF;
END $$;

INSERT INTO arb.process_registry(
  process_name,phase_no,process_group,description,owner_team,active_flag
)
VALUES
('RETAIL_R1C_COMPILER_REGISTER',2,'RETAIL_AUTOMATION','Register an immutable R1C compiler implementation authority candidate.','TCDS Retail Automation',true),
('RETAIL_R1C_COMPILER_CERTIFY',2,'RETAIL_AUTOMATION','Certify exact TypeScript+SQL compiler implementation authority.','TCDS Retail Automation',true),
('RETAIL_R1C_COMPILER_SUSPEND',2,'RETAIL_AUTOMATION','Suspend a certified R1C compiler authority.','TCDS Retail Automation',true),
('RETAIL_R1C_COMPILE_ROUTE',2,'RETAIL_AUTOMATION','Compile one exact effective R1B route into an immutable search job.','TCDS Retail Automation',true),
('RETAIL_R1C_COMPILE_ALL',2,'RETAIL_AUTOMATION','Compile all current effective R1B routes.','TCDS Retail Automation',true),
('RETAIL_R1C_CERTIFY',2,'RETAIL_AUTOMATION','Execute R1C passive, active-negative and deterministic-replay freeze certification.','TCDS Retail Automation',true)
ON CONFLICT(process_name) DO NOTHING;

-- ---------- COMMON HASH -----------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1c_sha256_text(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT encode(digest(convert_to(p_text,'UTF8'),'sha256'),'hex') $$;

CREATE OR REPLACE FUNCTION retail.r1c_sha256_jsonb(p_doc jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT retail.r1c_sha256_text(p_doc::text) $$;

-- ---------- EXACT R1B CERTIFICATION BINDING --------------------------------
CREATE TABLE IF NOT EXISTS retail.r1c_r1b_certification_binding (
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  r1b_schema_version text NOT NULL,
  r1b_certification_run_id uuid NOT NULL
    REFERENCES retail.r1b_certification_runs(id) ON DELETE RESTRICT,
  r1b_package_sha256 text NOT NULL CHECK(r1b_package_sha256 ~ '^[0-9a-f]{64}$'),
  r1b_evidence_manifest_sha256 text NOT NULL CHECK(r1b_evidence_manifest_sha256 ~ '^[0-9a-f]{64}$'),
  r1b_effective_routes_view_sha256 text NOT NULL CHECK(r1b_effective_routes_view_sha256 ~ '^[0-9a-f]{64}$'),
  bound_by text NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1c_r1b_binding_is_current()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      b.r1b_schema_version='3.0.0'
      AND s.schema_version=b.r1b_schema_version
      AND cr.id=b.r1b_certification_run_id
      AND cr.certification_status='CERTIFIED'
      AND cr.id = (
        SELECT x.id
        FROM retail.r1b_certification_runs x
        WHERE x.completed_at IS NOT NULL
        ORDER BY x.completed_at DESC, x.id::text DESC
        LIMIT 1
      )
      AND cr.package_sha256=b.r1b_package_sha256
      AND cr.evidence_manifest_sha256=b.r1b_evidence_manifest_sha256
      AND b.r1b_effective_routes_view_sha256 =
          retail.r1c_sha256_text(pg_get_viewdef('retail.effective_search_routes'::regclass,true))
    FROM retail.r1c_r1b_certification_binding b
    JOIN retail.r1b_schema_state s ON s.singleton=true
    JOIN retail.r1b_certification_runs cr ON cr.id=b.r1b_certification_run_id
    WHERE b.singleton=true
  ),false)
$$;

-- ---------- ROUTE COMPILE PROFILE -------------------------------------------
-- R1C owns how an already-approved R1B route is compiled, not where it routes.
CREATE TABLE IF NOT EXISTS retail.search_route_compile_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  route_id uuid NOT NULL UNIQUE
    REFERENCES retail.search_route_bindings(id) ON DELETE RESTRICT,
  route_authority_hash text NOT NULL CHECK(route_authority_hash ~ '^[0-9a-f]{64}$'),
  compile_mode text NOT NULL CHECK(compile_mode IN (
    'keyword','category','product_url','store_inventory'
  )),
  required_fields jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK(jsonb_typeof(required_fields)='array'),
  query_policy jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK(jsonb_typeof(query_policy)='object'),
  profile_status text NOT NULL DEFAULT 'active'
    CHECK(profile_status IN ('active','suspended','retired')),
  profile_sha256 text NOT NULL CHECK(profile_sha256 ~ '^[0-9a-f]{64}$'),
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION retail.r1c_compile_profile_document(
  p_row retail.search_route_compile_profiles
)
RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'route_id',p_row.route_id,
    'route_authority_hash',p_row.route_authority_hash,
    'compile_mode',p_row.compile_mode,
    'required_fields',p_row.required_fields,
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
    IF NEW.compile_mode='store_inventory'
       AND NOT (NEW.required_fields ? 'store_id') THEN
      RAISE EXCEPTION 'store_inventory profile must require store_id';
    END IF;
    NEW.profile_sha256:=retail.r1c_sha256_jsonb(retail.r1c_compile_profile_document(NEW));
    RETURN NEW;
  END IF;

  IF (to_jsonb(NEW)-ARRAY['profile_status'])
     IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['profile_status']) THEN
    RAISE EXCEPTION 'R1C compile profile content is immutable; create replacement route/profile';
  END IF;

  IF OLD.profile_status='retired' AND NEW.profile_status<>'retired' THEN
    RAISE EXCEPTION 'Retired compile profile is terminal';
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1c_compile_profile_guard ON retail.search_route_compile_profiles;
CREATE TRIGGER trg_r1c_compile_profile_guard
BEFORE INSERT OR UPDATE OR DELETE ON retail.search_route_compile_profiles
FOR EACH ROW EXECUTE FUNCTION retail.r1c_compile_profile_guard();

-- ---------- INPUT CONTRACT VALIDATION ---------------------------------------
CREATE OR REPLACE FUNCTION retail.r1c_validate_input_contract(
  p_contract jsonb,
  p_compile_mode text,
  p_required_fields jsonb
)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_transport text;
  v_field text;
  v_mode_field text;
  v_allowed_fields constant text[] := ARRAY[
    'query','category','product_url','store_id','postal_code','region','result_limit'
  ];
BEGIN
  IF p_contract IS NULL OR jsonb_typeof(p_contract)<>'object' THEN
    RAISE EXCEPTION 'Input contract must be a JSON object';
  END IF;

  v_transport:=NULLIF(p_contract->>'transport','');
  IF v_transport IS NULL OR v_transport NOT IN ('env','json','query','hybrid') THEN
    RAISE EXCEPTION 'Unsupported or missing input contract transport %',v_transport;
  END IF;

  IF NOT (p_contract ? 'compile_modes')
     OR jsonb_typeof(p_contract->'compile_modes')<>'array'
     OR jsonb_array_length(p_contract->'compile_modes')=0 THEN
    RAISE EXCEPTION 'compile_modes must be a non-empty array';
  END IF;

  IF COALESCE((p_contract->'compile_modes') ? p_compile_mode,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Compile mode % not certified by input contract',p_compile_mode;
  END IF;

  IF NOT (p_contract ? 'field_map')
     OR jsonb_typeof(p_contract->'field_map')<>'object'
     OR jsonb_object_length(p_contract->'field_map')=0 THEN
    RAISE EXCEPTION 'field_map must be a non-empty object';
  END IF;

  IF p_required_fields IS NULL OR jsonb_typeof(p_required_fields)<>'array' THEN
    RAISE EXCEPTION 'required_fields must be an array';
  END IF;

  -- Only canonical fields may be requested/mapped.
  FOR v_field IN SELECT key FROM jsonb_each(p_contract->'field_map')
  LOOP
    IF NOT (v_field = ANY(v_allowed_fields)) THEN
      RAISE EXCEPTION 'Unknown canonical field in field_map: %',v_field;
    END IF;
    IF NULLIF(p_contract#>>ARRAY['field_map',v_field],'') IS NULL THEN
      RAISE EXCEPTION 'Empty target mapping for canonical field %',v_field;
    END IF;
  END LOOP;

  FOR v_field IN SELECT jsonb_array_elements_text(p_required_fields)
  LOOP
    IF NOT (v_field = ANY(v_allowed_fields)) THEN
      RAISE EXCEPTION 'Unknown required canonical field %',v_field;
    END IF;
    IF NULLIF(p_contract#>>ARRAY['field_map',v_field],'') IS NULL THEN
      RAISE EXCEPTION 'Required field % lacks certified mapping',v_field;
    END IF;
  END LOOP;

  -- Compile-mode minimum mapping is mandatory even if profile omitted it.
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
    RAISE EXCEPTION
      'Compile mode % requires field_map.%',p_compile_mode,v_mode_field;
  END IF;

  -- Reject multiple canonical fields mapping to one concrete adapter field.
  IF EXISTS(
    SELECT 1
    FROM (
      SELECT value,count(*) n
      FROM jsonb_each_text(p_contract->'field_map')
      GROUP BY value HAVING count(*)>1
    ) d
  ) THEN
    RAISE EXCEPTION 'Input contract maps multiple canonical fields to the same adapter field';
  END IF;

  -- Legacy aliases must never coexist with canonical V2 field_map.
  IF p_contract ? 'keyword_env'
     OR p_contract ? 'store_id_env'
     OR p_contract ? 'postal_code_env'
     OR p_contract ? 'region_env'
     OR p_contract ? 'result_limit_env' THEN
    RAISE EXCEPTION
      'Legacy *_env mappings are prohibited in certified R1C V2 contracts; use field_map only';
  END IF;
END $$;

-- ---------- DETERMINISTIC QUERY NORMALIZER ----------------------------------
CREATE OR REPLACE FUNCTION retail.r1c_build_query(
  p_brand text,
  p_model_family text,
  p_terms jsonb
)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  WITH raw(v,ord) AS (
    SELECT p_brand,0
    UNION ALL SELECT p_model_family,1
    UNION ALL
    SELECT x.value,100+x.ordinality::int
    FROM jsonb_array_elements_text(COALESCE(p_terms,'[]'::jsonb))
         WITH ORDINALITY x(value,ordinality)
  ),
  cleaned AS (
    SELECT regexp_replace(btrim(v),'\s+',' ','g') v,ord
    FROM raw WHERE NULLIF(btrim(v),'') IS NOT NULL
  ),
  dedup AS (
    SELECT DISTINCT ON (lower(v)) v,ord
    FROM cleaned
    ORDER BY lower(v),ord
  )
  SELECT string_agg(v,' ' ORDER BY ord,lower(v))
  FROM dedup
$$;


CREATE OR REPLACE FUNCTION retail.r1c_create_compile_profile(
  p_route_id uuid,
  p_compile_mode text,
  p_required_fields jsonb,
  p_query_policy jsonb,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  r record;
  v_id uuid;
BEGIN
  SELECT * INTO r
  FROM retail.effective_search_routes
  WHERE route_id=p_route_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Compile profile creation blocked: route is not effective';
  END IF;

  PERFORM retail.r1c_validate_input_contract(
    r.input_contract_json,p_compile_mode,p_required_fields
  );

  IF p_compile_mode='keyword' AND r.supports_keyword_search IS NOT TRUE THEN
    RAISE EXCEPTION 'Adapter does not support keyword mode';
  ELSIF p_compile_mode='category' AND r.supports_category_search IS NOT TRUE THEN
    RAISE EXCEPTION 'Adapter does not support category mode';
  ELSIF p_compile_mode='product_url' AND r.supports_product_url IS NOT TRUE THEN
    RAISE EXCEPTION 'Adapter does not support product_url mode';
  ELSIF p_compile_mode='store_inventory' AND r.supports_store_id IS NOT TRUE THEN
    RAISE EXCEPTION 'Adapter does not support store_inventory mode';
  END IF;

  IF p_required_fields ? 'postal_code'
     AND r.supports_postal_code IS NOT TRUE THEN
    RAISE EXCEPTION 'Profile requires postal_code but adapter is not certified for it';
  END IF;

  IF p_required_fields ? 'region'
     AND r.supports_region IS NOT TRUE THEN
    RAISE EXCEPTION 'Profile requires region but adapter is not certified for it';
  END IF;

  INSERT INTO retail.search_route_compile_profiles(
    route_id,route_authority_hash,compile_mode,required_fields,
    query_policy,profile_sha256,created_by
  )
  VALUES(
    r.route_id,r.route_authority_hash,p_compile_mode,p_required_fields,
    COALESCE(p_query_policy,'{}'::jsonb),repeat('0',64),p_actor
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

-- ---------- COMPILER VERSION / FULL AUTHORITY -------------------------------
CREATE TABLE IF NOT EXISTS retail.search_compiler_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  compiler_code text NOT NULL,
  compiler_version text NOT NULL,

  typescript_wrapper_ref text NOT NULL,
  typescript_wrapper_sha256 text NOT NULL CHECK(typescript_wrapper_sha256 ~ '^[0-9a-f]{64}$'),
  sql_migration_ref text NOT NULL,
  sql_migration_sha256 text NOT NULL CHECK(sql_migration_sha256 ~ '^[0-9a-f]{64}$'),

  normalized_job_function_sha256 text NOT NULL CHECK(normalized_job_function_sha256 ~ '^[0-9a-f]{64}$'),
  adapter_payload_function_sha256 text NOT NULL CHECK(adapter_payload_function_sha256 ~ '^[0-9a-f]{64}$'),
  compile_route_function_sha256 text NOT NULL CHECK(compile_route_function_sha256 ~ '^[0-9a-f]{64}$'),
  currentness_function_sha256 text NOT NULL CHECK(currentness_function_sha256 ~ '^[0-9a-f]{64}$'),

  compiler_contract_json jsonb NOT NULL CHECK(jsonb_typeof(compiler_contract_json)='object'),
  compiler_contract_sha256 text NOT NULL CHECK(compiler_contract_sha256 ~ '^[0-9a-f]{64}$'),

  qa_evidence_sha256 text CHECK(qa_evidence_sha256 IS NULL OR qa_evidence_sha256 ~ '^[0-9a-f]{64}$'),
  compiler_authority_sha256 text NOT NULL CHECK(compiler_authority_sha256 ~ '^[0-9a-f]{64}$'),

  certification_status text NOT NULL DEFAULT 'uncertified'
    CHECK(certification_status IN ('uncertified','certified','suspended','retired')),
  certified_by text,
  certified_at timestamptz,

  source_process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE(compiler_code,compiler_version)
);

CREATE OR REPLACE FUNCTION retail.r1c_function_sha256(p_regprocedure regprocedure)
RETURNS text
LANGUAGE sql STABLE
AS $$
  SELECT retail.r1c_sha256_text(pg_get_functiondef(p_regprocedure))
$$;

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
    'normalized_job_function_sha256',p_row.normalized_job_function_sha256,
    'adapter_payload_function_sha256',p_row.adapter_payload_function_sha256,
    'compile_route_function_sha256',p_row.compile_route_function_sha256,
    'currentness_function_sha256',p_row.currentness_function_sha256,
    'compiler_contract_sha256',p_row.compiler_contract_sha256,
    'qa_evidence_sha256',p_row.qa_evidence_sha256
  )
$$;

-- ---------- COMPILATIONS -----------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.search_job_compilations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  compilation_key text NOT NULL UNIQUE,

  route_id uuid NOT NULL REFERENCES retail.search_route_bindings(id) ON DELETE RESTRICT,
  route_authority_hash text NOT NULL CHECK(route_authority_hash ~ '^[0-9a-f]{64}$'),
  compile_profile_id uuid NOT NULL REFERENCES retail.search_route_compile_profiles(id) ON DELETE RESTRICT,
  compile_profile_sha256 text NOT NULL CHECK(compile_profile_sha256 ~ '^[0-9a-f]{64}$'),

  target_id uuid NOT NULL REFERENCES retail.search_targets(id) ON DELETE RESTRICT,
  r1a_revision_id uuid NOT NULL REFERENCES retail.search_target_revisions(id) ON DELETE RESTRICT,
  r1a_revision_hash text NOT NULL CHECK(r1a_revision_hash ~ '^[0-9a-f]{64}$'),

  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  collection_source_id uuid NOT NULL REFERENCES retail.platform_collection_sources(id) ON DELETE RESTRICT,
  adapter_id uuid NOT NULL REFERENCES retail.retail_search_adapters(id) ON DELETE RESTRICT,
  location_id uuid REFERENCES retail.search_locations(id) ON DELETE RESTRICT,

  compiler_version_id uuid NOT NULL REFERENCES retail.search_compiler_versions(id) ON DELETE RESTRICT,
  compiler_authority_sha256 text NOT NULL CHECK(compiler_authority_sha256 ~ '^[0-9a-f]{64}$'),

  normalized_job_json jsonb NOT NULL CHECK(jsonb_typeof(normalized_job_json)='object'),
  normalized_job_sha256 text NOT NULL CHECK(normalized_job_sha256 ~ '^[0-9a-f]{64}$'),
  adapter_payload_json jsonb NOT NULL CHECK(jsonb_typeof(adapter_payload_json)='object'),
  adapter_payload_sha256 text NOT NULL CHECK(adapter_payload_sha256 ~ '^[0-9a-f]{64}$'),
  compilation_evidence_json jsonb NOT NULL CHECK(jsonb_typeof(compilation_evidence_json)='object'),
  compilation_evidence_sha256 text NOT NULL CHECK(compilation_evidence_sha256 ~ '^[0-9a-f]{64}$'),

  compilation_status text NOT NULL DEFAULT 'compiled'
    CHECK(compilation_status IN ('compiled','invalidated','superseded')),
  source_process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text NOT NULL,
  compiled_by text NOT NULL,
  compiled_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE(route_id,route_authority_hash,compile_profile_id,compiler_version_id)
);

-- Functions are created before compiler registration so their exact definitions can be hashed.

CREATE OR REPLACE FUNCTION retail.r1c_normalized_job_document(
  p_route_id uuid,
  p_profile_id uuid
)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT jsonb_build_object(
    'schema_version','r1c-normalized-job-v2',
    'route_id',r.route_id,
    'route_authority_hash',r.route_authority_hash,
    'compile_profile',jsonb_build_object(
      'profile_id',p.id,
      'profile_sha256',p.profile_sha256,
      'compile_mode',p.compile_mode,
      'required_fields',p.required_fields
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
      'platform_id',r.platform_id,'platform_code',r.platform_code,
      'platform_name',r.platform_name,'base_url',r.base_url
    ),
    'source',jsonb_build_object(
      'collection_source_id',r.collection_source_id,
      'source_code',r.source_code,'source_name',r.source_name,
      'source_url',r.source_url,'source_type',r.source_type,
      'source_scope',r.source_scope,'collection_method',r.collection_method,
      'dataset_id',r.dataset_id,'unlocker_zone',r.unlocker_zone,
      'request_overrides',r.request_overrides,
      'pagination_policy',r.pagination_policy,
      'qualification_policy',r.qualification_policy
    ),
    'adapter',jsonb_build_object(
      'adapter_id',r.adapter_id,'adapter_code',r.adapter_code,
      'adapter_version',r.adapter_version,
      'implementation_ref',r.implementation_ref,
      'implementation_sha256',r.implementation_sha256,
      'input_contract_sha256',r.input_contract_sha256,
      'capability_sha256',r.capability_sha256,
      'certification_fingerprint_hash',r.certification_fingerprint_hash
    ),
    'location',CASE WHEN r.location_id IS NULL THEN NULL ELSE jsonb_build_object(
      'location_id',r.location_id,'location_code',r.location_code,
      'location_type',r.location_type,'country_code',r.country_code,
      'state_code',r.state_code,'metro_name',r.metro_name,
      'postal_code',r.postal_code,'retailer_store_id',r.retailer_store_id,
      'display_name',r.display_name
    ) END
  )
  FROM retail.effective_search_routes r
  JOIN retail.search_route_compile_profiles p ON p.id=p_profile_id
  WHERE r.route_id=p_route_id
    AND p.route_id=r.route_id
    AND p.route_authority_hash=r.route_authority_hash
    AND p.profile_status='active'
    AND p.profile_sha256=retail.r1c_sha256_jsonb(retail.r1c_compile_profile_document(p))
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
  v_payload jsonb := '{}'::jsonb;
  v_values jsonb := '{}'::jsonb;
  v_query text;
  v_field text;
  v_target_name text;
BEGIN
  SELECT * INTO r FROM retail.effective_search_routes WHERE route_id=p_route_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1C compile blocked: route not effective';
  END IF;

  SELECT * INTO p
  FROM retail.search_route_compile_profiles
  WHERE id=p_profile_id AND route_id=p_route_id AND profile_status='active';

  IF NOT FOUND OR p.route_authority_hash<>r.route_authority_hash
     OR p.profile_sha256<>retail.r1c_sha256_jsonb(retail.r1c_compile_profile_document(p)) THEN
    RAISE EXCEPTION 'R1C compile blocked: compile profile stale/invalid';
  END IF;

  v_contract:=r.input_contract_json;
  PERFORM retail.r1c_validate_input_contract(v_contract,p.compile_mode,p.required_fields);

  IF p.compile_mode='keyword' AND NOT r.supports_keyword_search THEN
    RAISE EXCEPTION 'Keyword compile mode not supported by certified adapter';
  ELSIF p.compile_mode='category' AND NOT r.supports_category_search THEN
    RAISE EXCEPTION 'Category compile mode not supported';
  ELSIF p.compile_mode='product_url' AND NOT r.supports_product_url THEN
    RAISE EXCEPTION 'Product URL compile mode not supported';
  ELSIF p.compile_mode='store_inventory' AND NOT r.supports_store_id THEN
    RAISE EXCEPTION 'Store inventory compile mode not supported';
  END IF;

  v_query:=retail.r1c_build_query(r.brand,r.model_family,r.include_terms);

  IF p.compile_mode='keyword' THEN
    IF NULLIF(v_query,'') IS NULL THEN RAISE EXCEPTION 'No deterministic query available'; END IF;
    v_values:=v_values||jsonb_build_object('query',v_query);
  ELSIF p.compile_mode='category' THEN
    IF NULLIF(r.category_key,'') IS NULL THEN RAISE EXCEPTION 'category_key missing'; END IF;
    v_values:=v_values||jsonb_build_object('category',r.category_key);
  ELSIF p.compile_mode='product_url' THEN
    IF NULLIF(r.routing_policy->>'product_url','') IS NULL THEN
      RAISE EXCEPTION 'routing_policy.product_url missing';
    END IF;
    v_values:=v_values||jsonb_build_object('product_url',r.routing_policy->>'product_url');
  ELSIF p.compile_mode='store_inventory' THEN
    IF r.location_type<>'store' OR r.retailer_store_id IS NULL THEN
      RAISE EXCEPTION 'store_inventory requires store location/store id';
    END IF;
    v_values:=v_values||jsonb_build_object('store_id',r.retailer_store_id);
  END IF;

  IF r.location_type='store' AND r.retailer_store_id IS NOT NULL THEN
    v_values:=v_values||jsonb_build_object('store_id',r.retailer_store_id);
  END IF;
  IF r.postal_code IS NOT NULL THEN
    v_values:=v_values||jsonb_build_object('postal_code',r.postal_code);
  END IF;
  IF r.location_type='region' THEN
    v_values:=v_values||jsonb_build_object('region',COALESCE(r.state_code,r.display_name));
  END IF;
  IF r.supports_result_limit THEN
    v_values:=v_values||jsonb_build_object('result_limit',r.discovery_result_limit);
  END IF;

  -- Contract required_fields are exact and route-specific.
  FOR v_field IN SELECT jsonb_array_elements_text(p.required_fields)
  LOOP
    IF NULLIF(v_values->>v_field,'') IS NULL THEN
      RAISE EXCEPTION 'Required compile value % missing for route',v_field;
    END IF;
  END LOOP;

  -- Map canonical values into the adapter-certified transport names.
  FOR v_field,v_target_name IN
    SELECT key,value FROM jsonb_each_text(v_contract->'field_map')
  LOOP
    IF v_values ? v_field THEN
      v_payload:=v_payload||jsonb_build_object(v_target_name,v_values->v_field);
    END IF;
  END LOOP;

  v_payload:=jsonb_build_object(
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

  RETURN v_payload;
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
  r record; p record; c record;
  v_normalized jsonb; v_payload jsonb; v_evidence jsonb;
  v_key text; v_id uuid;
BEGIN
  IF retail.r1c_r1b_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'R1C compile blocked: exact R1B certification binding not current';
  END IF;

  SELECT * INTO r FROM retail.effective_search_routes WHERE route_id=p_route_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'R1C compile blocked: route not effective'; END IF;

  SELECT * INTO p FROM retail.search_route_compile_profiles
  WHERE id=p_profile_id AND route_id=p_route_id AND profile_status='active';
  IF NOT FOUND OR p.route_authority_hash<>r.route_authority_hash THEN
    RAISE EXCEPTION 'R1C compile blocked: profile not current for route';
  END IF;

  SELECT * INTO c FROM retail.search_compiler_versions
  WHERE id=p_compiler_version_id AND certification_status='certified';
  IF NOT FOUND THEN RAISE EXCEPTION 'R1C compile blocked: compiler not certified'; END IF;

  IF c.compiler_authority_sha256 <>
     retail.r1c_sha256_jsonb(retail.r1c_compiler_authority_document(c)) THEN
    RAISE EXCEPTION 'R1C compiler authority fingerprint mismatch';
  END IF;

  IF c.normalized_job_function_sha256<>
     retail.r1c_function_sha256('retail.r1c_normalized_job_document(uuid,uuid)'::regprocedure)
     OR c.adapter_payload_function_sha256<>
     retail.r1c_function_sha256('retail.r1c_adapter_payload_document(uuid,uuid)'::regprocedure)
     OR c.compile_route_function_sha256<>
     retail.r1c_function_sha256('retail.r1c_compile_route(uuid,uuid,uuid,uuid,text,text)'::regprocedure)
     OR c.currentness_function_sha256<>
     retail.r1c_function_sha256('retail.r1c_compilation_is_current(uuid)'::regprocedure)
  THEN
    RAISE EXCEPTION 'R1C compiler SQL implementation drift detected';
  END IF;

  v_normalized:=retail.r1c_normalized_job_document(p_route_id,p_profile_id);
  v_payload:=retail.r1c_adapter_payload_document(p_route_id,p_profile_id);

  v_evidence:=jsonb_build_object(
    'r1b_certification_binding',(SELECT to_jsonb(b) FROM retail.r1c_r1b_certification_binding b WHERE singleton=true),
    'route_authority_hash',r.route_authority_hash,
    'r1a_revision_hash',r.r1a_revision_hash,
    'compile_profile_sha256',p.profile_sha256,
    'adapter_implementation_sha256',r.implementation_sha256,
    'adapter_input_contract_sha256',r.input_contract_sha256,
    'adapter_capability_sha256',r.capability_sha256,
    'adapter_certification_fingerprint_hash',r.certification_fingerprint_hash,
    'compiler_authority_sha256',c.compiler_authority_sha256
  );

  v_key:=retail.r1c_sha256_text(
    r.route_authority_hash||':'||p.profile_sha256||':'||
    c.compiler_authority_sha256||':'||
    retail.r1c_sha256_jsonb(v_normalized)||':'||
    retail.r1c_sha256_jsonb(v_payload)
  );

  INSERT INTO retail.search_job_compilations(
    compilation_key,route_id,route_authority_hash,compile_profile_id,compile_profile_sha256,
    target_id,r1a_revision_id,r1a_revision_hash,
    platform_id,collection_source_id,adapter_id,location_id,
    compiler_version_id,compiler_authority_sha256,
    normalized_job_json,normalized_job_sha256,
    adapter_payload_json,adapter_payload_sha256,
    compilation_evidence_json,compilation_evidence_sha256,
    source_process_run_id,source_correlation_id,compiled_by
  )
  VALUES(
    v_key,r.route_id,r.route_authority_hash,p.id,p.profile_sha256,
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

CREATE OR REPLACE FUNCTION retail.r1c_compilation_is_current(p_compilation_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      j.compilation_status='compiled'
      AND retail.r1c_r1b_binding_is_current()
      AND r.route_authority_hash=j.route_authority_hash
      AND p.profile_status='active'
      AND p.profile_sha256=j.compile_profile_sha256
      AND p.profile_sha256=retail.r1c_sha256_jsonb(retail.r1c_compile_profile_document(p))
      AND c.certification_status='certified'
      AND c.compiler_authority_sha256=j.compiler_authority_sha256
      AND c.compiler_authority_sha256=retail.r1c_sha256_jsonb(retail.r1c_compiler_authority_document(c))
      AND c.normalized_job_function_sha256=
          retail.r1c_function_sha256('retail.r1c_normalized_job_document(uuid,uuid)'::regprocedure)
      AND c.adapter_payload_function_sha256=
          retail.r1c_function_sha256('retail.r1c_adapter_payload_document(uuid,uuid)'::regprocedure)
      AND c.compile_route_function_sha256=
          retail.r1c_function_sha256('retail.r1c_compile_route(uuid,uuid,uuid,uuid,text,text)'::regprocedure)
      AND c.currentness_function_sha256=
          retail.r1c_function_sha256('retail.r1c_compilation_is_current(uuid)'::regprocedure)
      AND j.normalized_job_sha256=retail.r1c_sha256_jsonb(j.normalized_job_json)
      AND j.adapter_payload_sha256=retail.r1c_sha256_jsonb(j.adapter_payload_json)
      AND j.compilation_evidence_sha256=retail.r1c_sha256_jsonb(j.compilation_evidence_json)
    FROM retail.search_job_compilations j
    JOIN retail.effective_search_routes r ON r.route_id=j.route_id
    JOIN retail.search_route_compile_profiles p ON p.id=j.compile_profile_id
    JOIN retail.search_compiler_versions c ON c.id=j.compiler_version_id
    WHERE j.id=p_compilation_id
  ),false)
$$;

CREATE OR REPLACE VIEW retail.effective_compiled_search_jobs AS
SELECT j.*
FROM retail.search_job_compilations j
WHERE retail.r1c_compilation_is_current(j.id)=true;

COMMENT ON VIEW retail.effective_compiled_search_jobs IS
'R1C sole R1D input. R1D must also runtime-attest retailer adapter and R1C compiler authority before dispatch.';

-- ---------- COMPILER CERTIFICATION AUTHORITY -------------------------------
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
  IF p_qa_evidence_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid QA evidence SHA';
  END IF;

  SELECT * INTO c FROM retail.search_compiler_versions
  WHERE id=p_compiler_id FOR UPDATE;
  IF NOT FOUND OR c.certification_status<>'uncertified' THEN
    RAISE EXCEPTION 'Compiler missing or not eligible';
  END IF;

  IF c.compiler_contract_sha256<>retail.r1c_sha256_jsonb(c.compiler_contract_json) THEN
    RAISE EXCEPTION 'Compiler contract SHA mismatch';
  END IF;

  -- Phase 1: finalize implementation/function/evidence fingerprints while
  -- compiler remains UNCERTIFIED, so immutable-certified guard is not bypassed.
  UPDATE retail.search_compiler_versions
  SET normalized_job_function_sha256=
        retail.r1c_function_sha256('retail.r1c_normalized_job_document(uuid,uuid)'::regprocedure),
      adapter_payload_function_sha256=
        retail.r1c_function_sha256('retail.r1c_adapter_payload_document(uuid,uuid)'::regprocedure),
      compile_route_function_sha256=
        retail.r1c_function_sha256('retail.r1c_compile_route(uuid,uuid,uuid,uuid,text,text)'::regprocedure),
      currentness_function_sha256=
        retail.r1c_function_sha256('retail.r1c_compilation_is_current(uuid)'::regprocedure),
      qa_evidence_sha256=p_qa_evidence_sha256,
      source_process_run_id=p_process_run_id,
      source_correlation_id=p_correlation_id
  WHERE id=p_compiler_id
    AND certification_status='uncertified';

  SELECT retail.r1c_sha256_jsonb(retail.r1c_compiler_authority_document(x))
  INTO v_authority
  FROM retail.search_compiler_versions x
  WHERE id=p_compiler_id;

  -- Phase 2: one-way certification transition with final authority SHA.
  UPDATE retail.search_compiler_versions
  SET compiler_authority_sha256=v_authority,
      certification_status='certified',
      certified_by=p_certifier,
      certified_at=now()
  WHERE id=p_compiler_id
    AND certification_status='uncertified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Compiler certification race/state transition failed';
  END IF;

  SELECT * INTO c FROM retail.search_compiler_versions WHERE id=p_compiler_id;

  IF c.compiler_authority_sha256<>
     retail.r1c_sha256_jsonb(retail.r1c_compiler_authority_document(c)) THEN
    RAISE EXCEPTION 'Compiler authority SHA failed post-certification verification';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION retail.r1c_assert_runtime_compiler(
  p_compiler_id uuid,
  p_observed_typescript_sha256 text,
  p_observed_sql_migration_sha256 text
)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE c record;
BEGIN
  SELECT * INTO c FROM retail.search_compiler_versions
  WHERE id=p_compiler_id AND certification_status='certified';

  IF NOT FOUND THEN RAISE EXCEPTION 'R1C runtime compiler not certified'; END IF;

  IF c.typescript_wrapper_sha256<>p_observed_typescript_sha256
     OR c.sql_migration_sha256<>p_observed_sql_migration_sha256 THEN
    RAISE EXCEPTION 'R1C runtime compiler artifact SHA mismatch';
  END IF;

  IF c.compiler_authority_sha256<>retail.r1c_sha256_jsonb(retail.r1c_compiler_authority_document(c)) THEN
    RAISE EXCEPTION 'R1C runtime compiler authority fingerprint mismatch';
  END IF;
END $$;

-- ---------- IMMUTABILITY -----------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1c_compiler_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Compiler versions cannot be deleted'; END IF;
  IF TG_OP='UPDATE' AND OLD.certification_status='certified' THEN
    IF (to_jsonb(NEW)-ARRAY['certification_status'])
       IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['certification_status']) THEN
      RAISE EXCEPTION 'Certified compiler authority immutable; create new version';
    END IF;
    IF NEW.certification_status NOT IN ('certified','suspended','retired') THEN
      RAISE EXCEPTION 'Invalid certified compiler transition';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_r1c_compiler_guard ON retail.search_compiler_versions;
CREATE TRIGGER trg_r1c_compiler_guard
BEFORE UPDATE OR DELETE ON retail.search_compiler_versions
FOR EACH ROW EXECUTE FUNCTION retail.r1c_compiler_guard();

CREATE OR REPLACE FUNCTION retail.r1c_compilation_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Compiled jobs cannot be deleted'; END IF;
  IF (to_jsonb(NEW)-ARRAY['compilation_status'])
     IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['compilation_status']) THEN
    RAISE EXCEPTION 'Compiled job content is immutable';
  END IF;
  IF OLD.compilation_status IN ('invalidated','superseded')
     AND NEW.compilation_status<>OLD.compilation_status THEN
    RAISE EXCEPTION 'Terminal compilation cannot reactivate';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_r1c_compilation_guard ON retail.search_job_compilations;
CREATE TRIGGER trg_r1c_compilation_guard
BEFORE UPDATE OR DELETE ON retail.search_job_compilations
FOR EACH ROW EXECUTE FUNCTION retail.r1c_compilation_guard();

-- ---------- CERTIFICATION RUNS ----------------------------------------------
CREATE TABLE IF NOT EXISTS retail.r1c_certification_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  process_run_id uuid NOT NULL REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  certification_version text NOT NULL,
  r1b_certification_run_id uuid NOT NULL REFERENCES retail.r1b_certification_runs(id) ON DELETE RESTRICT,
  r1b_package_sha256 text NOT NULL,
  r1c_package_sha256 text NOT NULL,
  compiler_version_id uuid NOT NULL REFERENCES retail.search_compiler_versions(id) ON DELETE RESTRICT,
  compiler_authority_sha256 text NOT NULL,
  passive_results jsonb NOT NULL DEFAULT '[]'::jsonb,
  active_results jsonb NOT NULL DEFAULT '[]'::jsonb,
  replay_results jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence_manifest jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence_manifest_sha256 text NOT NULL,
  total_gates integer NOT NULL,
  passed_gates integer NOT NULL,
  failed_gates integer NOT NULL,
  certification_status text NOT NULL CHECK(certification_status IN ('CERTIFIED','FAILED')),
  certified_by text NOT NULL,
  completed_at timestamptz NOT NULL DEFAULT now()
);

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
      AND cr.compiler_version_id=p_compiler_version_id
      AND cr.compiler_authority_sha256=c.compiler_authority_sha256
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

CREATE OR REPLACE FUNCTION retail.r1c_assert_runtime_release(
  p_compilation_id uuid,
  p_observed_r1c_package_sha256 text
)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  j record;
  cr record;
BEGIN
  SELECT * INTO j
  FROM retail.effective_compiled_search_jobs
  WHERE id=p_compilation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1C runtime release blocked: compilation is not effective';
  END IF;

  IF retail.r1c_latest_certification_is_current(j.compiler_version_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'R1C runtime release blocked: latest R1C certification is not current/CERTIFIED';
  END IF;

  SELECT * INTO cr
  FROM retail.r1c_certification_runs
  WHERE id=(
    SELECT x.id
    FROM retail.r1c_certification_runs x
    WHERE x.completed_at IS NOT NULL
    ORDER BY x.completed_at DESC,x.id::text DESC
    LIMIT 1
  );

  IF cr.r1c_package_sha256 IS DISTINCT FROM p_observed_r1c_package_sha256 THEN
    RAISE EXCEPTION 'R1C runtime release blocked: package SHA mismatch';
  END IF;
END $$;

-- ---------- AUDIT ------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail_audit.r1c_log_retail_change()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail_audit
AS $$
DECLARE v_row jsonb; v_actor text;
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
    CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
    CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END,
    v_actor
  );
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;

DROP TRIGGER IF EXISTS trg_r1c_audit_profiles ON retail.search_route_compile_profiles;
CREATE TRIGGER trg_r1c_audit_profiles
AFTER INSERT OR UPDATE OR DELETE ON retail.search_route_compile_profiles
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1c_log_retail_change();
DROP TRIGGER IF EXISTS trg_r1c_audit_compilers ON retail.search_compiler_versions;
CREATE TRIGGER trg_r1c_audit_compilers
AFTER INSERT OR UPDATE OR DELETE ON retail.search_compiler_versions
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1c_log_retail_change();
DROP TRIGGER IF EXISTS trg_r1c_audit_compilations ON retail.search_job_compilations;
CREATE TRIGGER trg_r1c_audit_compilations
AFTER INSERT OR UPDATE OR DELETE ON retail.search_job_compilations
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1c_log_retail_change();

-- ---------- PRIVILEGE HARDENING ---------------------------------------------
REVOKE ALL ON FUNCTION retail.r1c_r1b_binding_is_current() FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1c_create_compile_profile(uuid,text,jsonb,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1c_normalized_job_document(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1c_adapter_payload_document(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1c_compile_route(uuid,uuid,uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1c_compilation_is_current(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1c_certify_compiler(uuid,text,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1c_assert_runtime_compiler(uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1c_latest_certification_is_current(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1c_assert_runtime_release(uuid,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION retail.r1c_create_compile_profile(uuid,text,jsonb,jsonb,text)
  TO retail_r1c_compiler;
GRANT EXECUTE ON FUNCTION retail.r1c_compile_route(uuid,uuid,uuid,uuid,text,text)
  TO retail_r1c_compiler;
GRANT EXECUTE ON FUNCTION retail.r1c_assert_runtime_compiler(uuid,text,text)
  TO retail_r1c_compiler;
GRANT EXECUTE ON FUNCTION retail.r1c_assert_runtime_release(uuid,text)
  TO retail_r1c_compiler;
GRANT EXECUTE ON FUNCTION retail.r1c_latest_certification_is_current(uuid)
  TO retail_r1c_compiler;
GRANT EXECUTE ON FUNCTION retail.r1c_certify_compiler(uuid,text,uuid,text,text)
  TO retail_r1c_certifier;

GRANT SELECT ON retail.effective_compiled_search_jobs TO retail_r1c_reader;
GRANT SELECT ON retail.search_compiler_versions TO retail_r1c_reader;
GRANT SELECT ON retail.search_route_compile_profiles TO retail_r1c_reader;
GRANT SELECT ON retail.r1c_certification_runs TO retail_r1c_reader;

REVOKE INSERT,UPDATE,DELETE ON retail.search_job_compilations FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE ON retail.search_compiler_versions FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE ON retail.search_route_compile_profiles FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE ON retail.r1c_certification_runs FROM PUBLIC;

COMMIT;
