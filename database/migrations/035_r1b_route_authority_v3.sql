BEGIN;

CREATE SCHEMA IF NOT EXISTS retail;
CREATE SCHEMA IF NOT EXISTS retail_audit;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================================
-- TCDS RETAIL R1B — PLATFORM, SOURCE, STORE & GEOGRAPHIC SEARCH AUTHORITY
-- GREEN TIER 1 HARDENED V3 FREEZE CANDIDATE
--
-- R1A = WHAT to search.
-- R1B = WHERE / THROUGH WHAT APPROVED PATH to search.
-- R1C/R1D = job compilation, cadence, budget, dispatch.
-- R1E = returned-item qualification.
-- ARB/ERIP/later domains = profitability, capital, purchase, checkout authority.
-- ============================================================================

-- ---------- PRE-FLIGHT -------------------------------------------------------
DO $$
DECLARE
  v_version text;
BEGIN
  IF to_regclass('retail.r1b_schema_state') IS NULL THEN
    IF to_regclass('retail.search_locations') IS NOT NULL
       OR to_regclass('retail.retail_search_adapters') IS NOT NULL
       OR to_regclass('retail.search_route_bindings') IS NOT NULL
       OR to_regclass('retail.effective_search_routes') IS NOT NULL THEN
      RAISE EXCEPTION
        'R1B V3 preflight failed: prior R1B objects exist without a V2 marker. Do not silently overwrite. Roll back or explicitly migrate the prior package.';
    END IF;
  ELSE
    SELECT schema_version INTO v_version
    FROM retail.r1b_schema_state
    WHERE singleton=true;

    IF v_version IS DISTINCT FROM '3.0.0' THEN
      RAISE EXCEPTION
        'R1B V3 preflight failed: existing schema version % is not 3.0.0', v_version;
    END IF;
  END IF;

  IF to_regclass('retail.effective_search_targets') IS NULL THEN
    RAISE EXCEPTION 'R1B V3 requires certified R1A effective_search_targets';
  END IF;

  IF to_regclass('retail.r1a_schema_state') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM retail.r1a_schema_state
       WHERE singleton=true AND schema_version='2.0.0'
     ) THEN
    RAISE EXCEPTION
      'R1B V3 requires exact upstream R1A schema version 2.0.0';
  END IF;

  IF to_regclass('retail.retail_platforms') IS NULL
     OR to_regclass('retail.platform_collection_sources') IS NULL
     OR to_regclass('retail.platform_collection_configs') IS NULL
     OR to_regclass('retail_audit.retail_change_log') IS NULL
     OR to_regclass('arb.process_registry') IS NULL
     OR to_regclass('arb.process_runs') IS NULL THEN
    RAISE EXCEPTION 'R1B V3 preflight failed: required retail/ARB authority objects missing';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS retail.r1b_schema_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton=true),
  schema_version text NOT NULL,
  ownership_doctrine text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user
);

INSERT INTO retail.r1b_schema_state(singleton,schema_version,ownership_doctrine)
VALUES(
  true,
  '3.0.0',
  'R1B owns platform/source/adapter/location routing authority only. R1A source-type hints are non-authoritative. R1C/R1D own execution, cadence and budget. ARB/ERIP own economics, capital and purchase.'
)
ON CONFLICT(singleton) DO NOTHING;

-- Exact upstream R1A certification binding. This is populated only after the
-- R1A QA certification artifact/package identity has been verified.
CREATE TABLE retail.r1b_r1a_certification_binding (
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  r1a_schema_version text NOT NULL,
  r1a_package_sha256 text NOT NULL CHECK(r1a_package_sha256 ~ '^[0-9a-f]{64}$'),
  r1a_certification_evidence_sha256 text NOT NULL CHECK(r1a_certification_evidence_sha256 ~ '^[0-9a-f]{64}$'),
  r1a_effective_view_sha256 text NOT NULL CHECK(r1a_effective_view_sha256 ~ '^[0-9a-f]{64}$'),
  bound_by text NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE retail.r1b_certification_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  certification_version text NOT NULL,
  r1a_package_sha256 text NOT NULL,
  package_sha256 text,
  evidence_manifest jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence_manifest_sha256 text,
  total_gates integer NOT NULL DEFAULT 0,
  passed_gates integer NOT NULL DEFAULT 0,
  failed_gates integer NOT NULL DEFAULT 0,
  certification_status text NOT NULL CHECK(certification_status IN ('STARTED','CERTIFIED','FAILED')),
  certified_by text,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

INSERT INTO arb.process_registry(
  process_name,phase_no,process_group,description,owner_team,active_flag
)
VALUES(
  'RETAIL_R1B_ROUTE_AUTHORITY_SYNC',
  2,
  'RETAIL_AUTOMATION',
  'Validates and certifies retail platform/source/adapter/store/geographic route authority for effective R1A targets.',
  'TCDS Retail Automation',
  true
)
ON CONFLICT(process_name) DO NOTHING;

INSERT INTO arb.process_registry(process_name,phase_no,process_group,description,owner_team,active_flag)
VALUES
('RETAIL_R1B_ADAPTER_INVENTORY',2,'RETAIL_AUTOMATION','Inventory/version retail search adapters without certifying them.','TCDS Retail Automation',true),
('RETAIL_R1B_ADAPTER_CERTIFY',2,'RETAIL_AUTOMATION','Certify an immutable adapter artifact/input/capability/evidence identity.','TCDS Retail Automation',true),
('RETAIL_R1B_LOCATION_APPROVE',2,'RETAIL_AUTOMATION','Verify and approve governed geographic/store identities.','TCDS Retail Automation',true),
('RETAIL_R1B_ROUTE_CREATE',2,'RETAIL_AUTOMATION','Create immutable R1B route authority snapshots.','TCDS Retail Automation',true),
('RETAIL_R1B_ROUTE_APPROVE',2,'RETAIL_AUTOMATION','Atomically approve only currently valid R1B routes.','TCDS Retail Automation',true),
('RETAIL_R1B_CERTIFY',2,'RETAIL_AUTOMATION','Execute active/passive R1B freeze-gate certification and seal evidence.','TCDS Retail Automation',true)
ON CONFLICT(process_name) DO NOTHING;

-- ---------- SHARED HASH ------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1b_sha256_jsonb(p_doc jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT encode(extensions.digest(convert_to(p_doc::text,'UTF8'),'sha256'),'hex')
$$;

-- ---------- LOCATION / STORE AUTHORITY --------------------------------------
CREATE TABLE retail.search_locations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  location_code text NOT NULL UNIQUE CHECK(location_code ~ '^[A-Z0-9_:-]+$'),
  location_type text NOT NULL CHECK(location_type IN (
    'national','region','state','metro','postal_code','store'
  )),

  -- Required only for retailer-specific store identities.
  platform_id uuid REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  parent_location_id uuid REFERENCES retail.search_locations(id) ON DELETE RESTRICT,

  country_code char(2) NOT NULL DEFAULT 'US',
  state_code text,
  metro_name text,
  postal_code text,
  retailer_store_id text,
  display_name text NOT NULL,
  latitude numeric(9,6),
  longitude numeric(9,6),

  location_status text NOT NULL DEFAULT 'draft' CHECK(location_status IN (
    'draft','verified','approved','suspended','retired'
  )),

  verification_method text,
  verification_evidence_json jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK(jsonb_typeof(verification_evidence_json)='object'),
  verification_evidence_hash text
    CHECK(verification_evidence_hash IS NULL OR verification_evidence_hash ~ '^[0-9a-f]{64}$'),
  verified_by text,
  verified_at timestamptz,

  approved_by text,
  approved_at timestamptz,
  suspended_reason text,

  metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(metadata)='object'),
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CHECK (
    (location_type='store' AND platform_id IS NOT NULL AND retailer_store_id IS NOT NULL)
    OR
    (location_type<>'store' AND retailer_store_id IS NULL)
  ),
  CHECK (location_type<>'postal_code' OR postal_code IS NOT NULL),
  CHECK (location_type<>'store' OR postal_code IS NOT NULL),
  CHECK (location_type<>'state' OR state_code IS NOT NULL),
  CHECK (location_type<>'metro' OR metro_name IS NOT NULL)
);

CREATE UNIQUE INDEX uq_r1b_store_platform_store_id
ON retail.search_locations(platform_id,retailer_store_id)
WHERE location_type='store';

CREATE INDEX idx_r1b_location_parent ON retail.search_locations(parent_location_id);
CREATE INDEX idx_r1b_location_geo ON retail.search_locations(location_type,country_code,state_code,postal_code);
CREATE INDEX idx_r1b_location_status ON retail.search_locations(location_status,location_type);

CREATE OR REPLACE FUNCTION retail.r1b_location_authority_document(p_location_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT jsonb_build_object(
    'id',l.id,
    'location_code',l.location_code,
    'location_type',l.location_type,
    'platform_id',l.platform_id,
    'parent_location_id',l.parent_location_id,
    'country_code',l.country_code,
    'state_code',l.state_code,
    'metro_name',l.metro_name,
    'postal_code',l.postal_code,
    'retailer_store_id',l.retailer_store_id,
    'display_name',l.display_name,
    'latitude',l.latitude,
    'longitude',l.longitude,
    'location_status',l.location_status,
    'verification_method',l.verification_method,
    'verification_evidence_hash',l.verification_evidence_hash
  )
  FROM retail.search_locations l
  WHERE l.id=p_location_id
$$;

CREATE OR REPLACE FUNCTION retail.r1b_location_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1B locations cannot be deleted; retire them';
  END IF;

  IF TG_OP='UPDATE' AND OLD.location_status='retired'
     AND NEW.location_status IS DISTINCT FROM 'retired' THEN
    RAISE EXCEPTION 'Retired R1B location is terminal';
  END IF;

  IF NEW.location_type='store' AND NEW.platform_id IS NULL THEN
    RAISE EXCEPTION 'Store location requires platform_id';
  END IF;

  IF NEW.parent_location_id IS NOT NULL THEN
    IF NEW.parent_location_id = NEW.id THEN
      RAISE EXCEPTION 'Location cannot be its own parent';
    END IF;

    IF EXISTS (
      WITH RECURSIVE ancestors AS (
        SELECT id,parent_location_id FROM retail.search_locations
        WHERE id=NEW.parent_location_id
        UNION ALL
        SELECT l.id,l.parent_location_id
        FROM retail.search_locations l
        JOIN ancestors a ON l.id=a.parent_location_id
      )
      SELECT 1 FROM ancestors WHERE id=NEW.id
    ) THEN
      RAISE EXCEPTION 'Geographic hierarchy cycle detected';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM retail.search_locations p
      WHERE p.id=NEW.parent_location_id
        AND (
          (p.location_type='national' AND NEW.location_type IN ('region','state','metro','postal_code','store'))
          OR (p.location_type='region' AND NEW.location_type IN ('state','metro','postal_code','store'))
          OR (p.location_type='state' AND NEW.location_type IN ('metro','postal_code','store'))
          OR (p.location_type='metro' AND NEW.location_type IN ('postal_code','store'))
          OR (p.location_type='postal_code' AND NEW.location_type='store')
        )
        AND (NEW.country_code IS NOT DISTINCT FROM p.country_code OR p.location_type='national')
        AND (p.state_code IS NULL OR NEW.state_code IS NOT DISTINCT FROM p.state_code)
        AND (
          NEW.location_type<>'store'
          OR p.platform_id IS NULL
          OR NEW.platform_id IS NOT DISTINCT FROM p.platform_id
        )
    ) THEN
      RAISE EXCEPTION 'Invalid geographic parent/child relationship';
    END IF;
  END IF;

  IF NEW.location_status IN ('verified','approved') THEN
    IF NEW.verification_method IS NULL
       OR NEW.verification_evidence_hash IS NULL
       OR NEW.verified_by IS NULL
       OR NEW.verified_at IS NULL THEN
      RAISE EXCEPTION 'Verified/approved R1B location requires verification evidence and verifier';
    END IF;
  END IF;

  IF NEW.location_status='approved'
     AND (NEW.approved_by IS NULL OR NEW.approved_at IS NULL) THEN
    RAISE EXCEPTION 'Approved R1B location requires approver and timestamp';
  END IF;

  IF TG_OP='UPDATE' AND NEW.location_status IS DISTINCT FROM OLD.location_status THEN
    IF OLD.location_status='draft' AND NEW.location_status NOT IN ('verified','retired') THEN
      RAISE EXCEPTION 'Invalid location transition % -> %',OLD.location_status,NEW.location_status;
    ELSIF OLD.location_status='verified' AND NEW.location_status NOT IN ('approved','suspended','retired') THEN
      RAISE EXCEPTION 'Invalid location transition % -> %',OLD.location_status,NEW.location_status;
    ELSIF OLD.location_status='approved' AND NEW.location_status NOT IN ('suspended','retired') THEN
      RAISE EXCEPTION 'Invalid location transition % -> %',OLD.location_status,NEW.location_status;
    ELSIF OLD.location_status='suspended' AND NEW.location_status NOT IN ('verified','retired') THEN
      RAISE EXCEPTION 'Invalid location transition % -> %',OLD.location_status,NEW.location_status;
    END IF;
  END IF;

  NEW.updated_at:=now();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1b_location_guard
BEFORE INSERT OR UPDATE OR DELETE ON retail.search_locations
FOR EACH ROW EXECUTE FUNCTION retail.r1b_location_guard();

-- ---------- VERSIONED ADAPTER AUTHORITY -------------------------------------
CREATE TABLE retail.retail_search_adapters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,

  adapter_type text NOT NULL CHECK(adapter_type IN (
    'search','product_detail','store_inventory','category_discovery','hybrid'
  )),
  adapter_code text NOT NULL CHECK(adapter_code ~ '^[a-z0-9_]+$'),
  adapter_version text NOT NULL,

  implementation_ref text NOT NULL,
  implementation_sha256 text NOT NULL CHECK(implementation_sha256 ~ '^[0-9a-f]{64}$'),
  git_commit_sha text CHECK(git_commit_sha IS NULL OR git_commit_sha ~ '^[0-9a-f]{7,64}$'),

  supports_keyword_search boolean NOT NULL DEFAULT false,
  supports_product_url boolean NOT NULL DEFAULT false,
  supports_category_search boolean NOT NULL DEFAULT false,
  supports_store_id boolean NOT NULL DEFAULT false,
  supports_postal_code boolean NOT NULL DEFAULT false,
  supports_region boolean NOT NULL DEFAULT false,
  supports_result_limit boolean NOT NULL DEFAULT false,

  supported_collection_methods jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK(jsonb_typeof(supported_collection_methods)='array'),
  supports_all_collection_methods boolean NOT NULL DEFAULT false,
  supported_source_types jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK(jsonb_typeof(supported_source_types)='array'),
  supports_all_source_types boolean NOT NULL DEFAULT false,

  input_contract_json jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK(jsonb_typeof(input_contract_json)='object'),
  input_contract_sha256 text NOT NULL CHECK(input_contract_sha256 ~ '^[0-9a-f]{64}$'),

  capability_json jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK(jsonb_typeof(capability_json)='object'),
  capability_sha256 text NOT NULL CHECK(capability_sha256 ~ '^[0-9a-f]{64}$'),

  certification_status text NOT NULL DEFAULT 'uncertified' CHECK(certification_status IN (
    'uncertified','test_only','partially_dynamic','certified_dynamic_search',
    'suspended','retired'
  )),
  certification_evidence_hash text
    CHECK(certification_evidence_hash IS NULL OR certification_evidence_hash ~ '^[0-9a-f]{64}$'),
  certification_fingerprint_hash text
    CHECK(certification_fingerprint_hash IS NULL OR certification_fingerprint_hash ~ '^[0-9a-f]{64}$'),
  certified_by text,
  certified_at timestamptz,
  suspended_reason text,

  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE(platform_id,adapter_code,adapter_version)
);

CREATE INDEX idx_r1b_adapter_platform_status
ON retail.retail_search_adapters(platform_id,certification_status,adapter_type);

CREATE OR REPLACE FUNCTION retail.r1b_adapter_capability_document(
  p_row retail.retail_search_adapters
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'supports_keyword_search',p_row.supports_keyword_search,
    'supports_product_url',p_row.supports_product_url,
    'supports_category_search',p_row.supports_category_search,
    'supports_store_id',p_row.supports_store_id,
    'supports_postal_code',p_row.supports_postal_code,
    'supports_region',p_row.supports_region,
    'supports_result_limit',p_row.supports_result_limit,
    'supported_collection_methods',p_row.supported_collection_methods,
    'supports_all_collection_methods',p_row.supports_all_collection_methods,
    'supported_source_types',p_row.supported_source_types,
    'supports_all_source_types',p_row.supports_all_source_types
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1b_adapter_certification_document(
  p_row retail.retail_search_adapters
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'platform_id',p_row.platform_id,
    'adapter_type',p_row.adapter_type,
    'adapter_code',p_row.adapter_code,
    'adapter_version',p_row.adapter_version,
    'implementation_ref',p_row.implementation_ref,
    'implementation_sha256',p_row.implementation_sha256,
    'git_commit_sha',p_row.git_commit_sha,
    'input_contract_sha256',p_row.input_contract_sha256,
    'capability_sha256',p_row.capability_sha256,
    'certification_evidence_hash',p_row.certification_evidence_hash
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1b_adapter_prepare()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.input_contract_sha256:=retail.r1b_sha256_jsonb(NEW.input_contract_json);
  NEW.capability_json:=retail.r1b_adapter_capability_document(NEW);
  NEW.capability_sha256:=retail.r1b_sha256_jsonb(NEW.capability_json);

  IF NEW.certification_status='certified_dynamic_search' THEN
    IF NEW.certification_evidence_hash IS NULL
       OR NEW.certified_by IS NULL
       OR NEW.certified_at IS NULL THEN
      RAISE EXCEPTION 'Certified adapter requires evidence hash, certifier and timestamp';
    END IF;

    IF NOT (
      NEW.supports_keyword_search
      OR NEW.supports_product_url
      OR NEW.supports_category_search
      OR NEW.supports_store_id
    ) THEN
      RAISE EXCEPTION 'Certified dynamic-search adapter has no usable search capability';
    END IF;

    IF jsonb_array_length(NEW.supported_collection_methods)=0
       AND NEW.supports_all_collection_methods IS NOT TRUE THEN
      RAISE EXCEPTION
        'Certified adapter must enumerate collection methods or explicitly certify wildcard support';
    END IF;

    IF jsonb_array_length(NEW.supported_source_types)=0
       AND NEW.supports_all_source_types IS NOT TRUE THEN
      RAISE EXCEPTION
        'Certified adapter must enumerate source types or explicitly certify wildcard support';
    END IF;

    NEW.certification_fingerprint_hash:=
      retail.r1b_sha256_jsonb(retail.r1b_adapter_certification_document(NEW));
  ELSE
    NEW.certification_fingerprint_hash:=NULL;
  END IF;

  NEW.updated_at:=now();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1b_adapter_prepare
BEFORE INSERT OR UPDATE ON retail.retail_search_adapters
FOR EACH ROW EXECUTE FUNCTION retail.r1b_adapter_prepare();

CREATE OR REPLACE FUNCTION retail.r1b_adapter_immutable_after_cert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1B adapters cannot be deleted; retire them';
  END IF;

  IF OLD.certification_status='retired'
     AND NEW.certification_status IS DISTINCT FROM 'retired' THEN
    RAISE EXCEPTION 'Retired adapter is terminal';
  END IF;

  IF OLD.certification_status='certified_dynamic_search' THEN
    IF (to_jsonb(NEW) - ARRAY[
          'certification_status','suspended_reason','updated_at'
        ])
       IS DISTINCT FROM
       (to_jsonb(OLD) - ARRAY[
          'certification_status','suspended_reason','updated_at'
        ]) THEN
      RAISE EXCEPTION
        'Certified adapter version is immutable. Create a new adapter_version for implementation/contract/capability changes.';
    END IF;

    IF NEW.certification_status NOT IN ('certified_dynamic_search','suspended','retired') THEN
      RAISE EXCEPTION 'Invalid certified adapter transition % -> %',
        OLD.certification_status,NEW.certification_status;
    END IF;
  END IF;

  IF OLD.certification_status='suspended'
     AND NEW.certification_status NOT IN ('suspended','retired') THEN
    RAISE EXCEPTION 'Suspended certified adapter cannot be silently re-certified; create a new version or explicit certification record';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1b_adapter_immutable_after_cert
BEFORE UPDATE OR DELETE ON retail.retail_search_adapters
FOR EACH ROW EXECUTE FUNCTION retail.r1b_adapter_immutable_after_cert();

CREATE OR REPLACE FUNCTION retail.r1b_adapter_is_certified_current(p_adapter_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      a.certification_status='certified_dynamic_search'
      AND a.certification_evidence_hash IS NOT NULL
      AND a.certified_by IS NOT NULL
      AND a.certified_at IS NOT NULL
      AND a.input_contract_sha256=retail.r1b_sha256_jsonb(a.input_contract_json)
      AND a.capability_sha256=retail.r1b_sha256_jsonb(retail.r1b_adapter_capability_document(a))
      AND a.certification_fingerprint_hash=
          retail.r1b_sha256_jsonb(retail.r1b_adapter_certification_document(a))
    FROM retail.retail_search_adapters a
    WHERE a.id=p_adapter_id
  ),false)
$$;

CREATE OR REPLACE FUNCTION retail.r1b_adapter_authority_document(p_adapter_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT jsonb_build_object(
    'id',a.id,
    'platform_id',a.platform_id,
    'adapter_type',a.adapter_type,
    'adapter_code',a.adapter_code,
    'adapter_version',a.adapter_version,
    'implementation_ref',a.implementation_ref,
    'implementation_sha256',a.implementation_sha256,
    'git_commit_sha',a.git_commit_sha,
    'input_contract_sha256',a.input_contract_sha256,
    'capability_sha256',a.capability_sha256,
    'certification_status',a.certification_status,
    'certification_evidence_hash',a.certification_evidence_hash,
    'certification_fingerprint_hash',a.certification_fingerprint_hash
  )
  FROM retail.retail_search_adapters a
  WHERE a.id=p_adapter_id
$$;

-- ---------- PLATFORM / SOURCE SNAPSHOT AUTHORITY -----------------------------
CREATE OR REPLACE FUNCTION retail.r1b_platform_authority_document(p_platform_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT jsonb_build_object(
    'id',p.id,
    'platform_code',p.platform_code,
    'base_url',p.base_url,
    'access_type',p.access_type::text,
    'status',p.status::text,
    'is_data_collection_supported',p.is_data_collection_supported,
    'max_daily_requests',p.max_daily_requests,
    'max_hourly_requests',p.max_hourly_requests
  )
  FROM retail.retail_platforms p WHERE p.id=p_platform_id
$$;

CREATE OR REPLACE FUNCTION retail.r1b_source_authority_document(p_source_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT jsonb_build_object(
    'id',s.id,
    'platform_id',s.platform_id,
    'config_id',s.config_id,
    'source_code',s.source_code,
    'source_url',s.source_url,
    'source_type',s.source_type,
    'source_scope',s.source_scope,
    'collection_method',s.collection_method,
    'dataset_id',s.dataset_id,
    'unlocker_zone',s.unlocker_zone,
    'required_store_id',s.required_store_id,
    'required_postal_code',s.required_postal_code,
    'is_approved',s.is_approved,
    'is_active',s.is_active,
    'request_overrides',s.request_overrides,
    'pagination_policy',s.pagination_policy,
    'qualification_policy',s.qualification_policy,
    'minimum_discount_percent',s.minimum_discount_percent,
    'maximum_effective_price',s.maximum_effective_price,
    'source_policy_mode',c.source_policy_mode,
    'collection_strategy',c.collection_strategy,
    'search_seed_json',c.search_seed_json,
    'category_seed_json',c.category_seed_json,
    'request_policy_json',c.request_policy_json,
    'parser_policy_json',c.parser_policy_json,
    'evidence_policy_json',c.evidence_policy_json,
    'discount_policy_version',c.discount_policy_version,
    'reject_unqualified_products',c.reject_unqualified_products,
    'config_active',CASE WHEN s.config_id IS NULL THEN true ELSE c.is_active END
  )
  FROM retail.platform_collection_sources s
  LEFT JOIN retail.platform_collection_configs c ON c.id=s.config_id
  WHERE s.id=p_source_id
$$;


-- ---------- RUNTIME ARTIFACT ATTESTATION CONTRACT ---------------------------
CREATE OR REPLACE FUNCTION retail.r1b_assert_runtime_adapter(
  p_adapter_id uuid,
  p_observed_implementation_sha256 text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  v_expected text;
BEGIN
  IF p_observed_implementation_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R1B runtime attestation requires lowercase SHA-256';
  END IF;

  SELECT implementation_sha256 INTO v_expected
  FROM retail.retail_search_adapters
  WHERE id=p_adapter_id
    AND retail.r1b_adapter_is_certified_current(id)=true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1B runtime attestation blocked: adapter is not currently certified';
  END IF;

  IF v_expected IS DISTINCT FROM p_observed_implementation_sha256 THEN
    RAISE EXCEPTION
      'R1B runtime attestation blocked: deployed implementation SHA mismatch';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION retail.r1b_r1a_binding_is_current()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      b.r1a_schema_version='2.0.0'
      AND EXISTS(
        SELECT 1 FROM retail.r1a_schema_state s
        WHERE s.singleton=true AND s.schema_version=b.r1a_schema_version
      )
      AND b.r1a_effective_view_sha256 =
          encode(extensions.digest(convert_to(pg_get_viewdef('retail.effective_search_targets'::regclass,true),'UTF8'),'sha256'),'hex')
    FROM retail.r1b_r1a_certification_binding b
    WHERE b.singleton=true
  ),false)
$$;

-- ---------- IMMUTABLE ROUTE AUTHORITY ---------------------------------------
CREATE TABLE retail.search_route_bindings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  route_code text NOT NULL UNIQUE CHECK(route_code ~ '^[A-Z0-9_:-]+$'),

  target_id uuid NOT NULL REFERENCES retail.search_targets(id) ON DELETE RESTRICT,
  r1a_revision_id uuid NOT NULL REFERENCES retail.search_target_revisions(id) ON DELETE RESTRICT,
  r1a_revision_hash text NOT NULL CHECK(r1a_revision_hash ~ '^[0-9a-f]{64}$'),

  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  collection_source_id uuid NOT NULL REFERENCES retail.platform_collection_sources(id) ON DELETE RESTRICT,
  adapter_id uuid NOT NULL REFERENCES retail.retail_search_adapters(id) ON DELETE RESTRICT,
  location_id uuid REFERENCES retail.search_locations(id) ON DELETE RESTRICT,

  route_status text NOT NULL DEFAULT 'draft'
    CHECK(route_status IN ('draft','approved','paused','retired')),

  -- R1B-owned routing semantics. No R1A desired_source_types dependency.
  routing_policy jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(routing_policy)='object'),

  platform_snapshot jsonb NOT NULL CHECK(jsonb_typeof(platform_snapshot)='object'),
  platform_snapshot_hash text NOT NULL CHECK(platform_snapshot_hash ~ '^[0-9a-f]{64}$'),
  source_snapshot jsonb NOT NULL CHECK(jsonb_typeof(source_snapshot)='object'),
  source_snapshot_hash text NOT NULL CHECK(source_snapshot_hash ~ '^[0-9a-f]{64}$'),
  adapter_snapshot jsonb NOT NULL CHECK(jsonb_typeof(adapter_snapshot)='object'),
  adapter_snapshot_hash text NOT NULL CHECK(adapter_snapshot_hash ~ '^[0-9a-f]{64}$'),
  location_snapshot jsonb CHECK(location_snapshot IS NULL OR jsonb_typeof(location_snapshot)='object'),
  location_snapshot_hash text CHECK(location_snapshot_hash IS NULL OR location_snapshot_hash ~ '^[0-9a-f]{64}$'),

  route_authority_hash text NOT NULL UNIQUE CHECK(route_authority_hash ~ '^[0-9a-f]{64}$'),

  approved_by text,
  approved_at timestamptz,
  created_by text NOT NULL,

  source_process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE(target_id,r1a_revision_id,platform_id,collection_source_id,adapter_id,location_id)
);

CREATE INDEX idx_r1b_routes_target ON retail.search_route_bindings(target_id,r1a_revision_id);
CREATE INDEX idx_r1b_routes_platform ON retail.search_route_bindings(platform_id,route_status);
CREATE INDEX idx_r1b_routes_source ON retail.search_route_bindings(collection_source_id,route_status);

CREATE OR REPLACE FUNCTION retail.r1b_route_authority_document(
  p_row retail.search_route_bindings
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'target_id',p_row.target_id,
    'r1a_revision_id',p_row.r1a_revision_id,
    'r1a_revision_hash',p_row.r1a_revision_hash,
    'platform_snapshot_hash',p_row.platform_snapshot_hash,
    'source_snapshot_hash',p_row.source_snapshot_hash,
    'adapter_snapshot_hash',p_row.adapter_snapshot_hash,
    'location_snapshot_hash',p_row.location_snapshot_hash,
    'routing_policy',p_row.routing_policy
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1b_prepare_route()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_target record;
  v_source record;
  v_adapter record;
  v_location record;
  v_doc jsonb;
BEGIN
  SELECT * INTO v_target
  FROM retail.effective_search_targets
  WHERE target_id=NEW.target_id AND revision_id=NEW.r1a_revision_id;

  IF NOT FOUND OR NEW.r1a_revision_hash IS DISTINCT FROM v_target.revision_hash THEN
    RAISE EXCEPTION 'R1B route blocked: target/revision is not current effective R1A authority';
  END IF;

  SELECT * INTO v_source
  FROM retail.platform_collection_sources
  WHERE id=NEW.collection_source_id;
  IF NOT FOUND OR v_source.platform_id IS DISTINCT FROM NEW.platform_id THEN
    RAISE EXCEPTION 'R1B route blocked: source missing or cross-platform';
  END IF;

  SELECT * INTO v_adapter
  FROM retail.retail_search_adapters
  WHERE id=NEW.adapter_id;
  IF NOT FOUND OR v_adapter.platform_id IS DISTINCT FROM NEW.platform_id THEN
    RAISE EXCEPTION 'R1B route blocked: adapter missing or cross-platform';
  END IF;

  IF NEW.location_id IS NOT NULL THEN
    SELECT * INTO v_location
    FROM retail.search_locations
    WHERE id=NEW.location_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'R1B route blocked: location missing';
    END IF;

    IF v_location.location_type='store'
       AND v_location.platform_id IS DISTINCT FROM NEW.platform_id THEN
      RAISE EXCEPTION 'R1B route blocked: store belongs to a different retailer';
    END IF;

    IF v_source.source_scope='store' AND v_location.location_type<>'store' THEN
      RAISE EXCEPTION 'Store-scoped source requires store location';
    END IF;

    IF v_source.source_scope='postal_code'
       AND v_location.location_type NOT IN ('postal_code','store') THEN
      RAISE EXCEPTION 'Postal-scoped source requires postal/store location';
    END IF;

    IF v_source.required_store_id IS NOT NULL
       AND v_location.retailer_store_id IS DISTINCT FROM v_source.required_store_id THEN
      RAISE EXCEPTION 'Required store ID mismatch';
    END IF;

    IF v_source.required_postal_code IS NOT NULL
       AND v_location.postal_code IS DISTINCT FROM v_source.required_postal_code THEN
      RAISE EXCEPTION 'Required postal code mismatch';
    END IF;
  ELSIF v_source.source_scope IN ('store','postal_code') THEN
    RAISE EXCEPTION 'Scoped source requires explicit location';
  END IF;

  NEW.platform_snapshot:=retail.r1b_platform_authority_document(NEW.platform_id);
  NEW.platform_snapshot_hash:=retail.r1b_sha256_jsonb(NEW.platform_snapshot);

  NEW.source_snapshot:=retail.r1b_source_authority_document(NEW.collection_source_id);
  NEW.source_snapshot_hash:=retail.r1b_sha256_jsonb(NEW.source_snapshot);

  NEW.adapter_snapshot:=retail.r1b_adapter_authority_document(NEW.adapter_id);
  NEW.adapter_snapshot_hash:=retail.r1b_sha256_jsonb(NEW.adapter_snapshot);

  IF NEW.location_id IS NOT NULL THEN
    NEW.location_snapshot:=retail.r1b_location_authority_document(NEW.location_id);
    NEW.location_snapshot_hash:=retail.r1b_sha256_jsonb(NEW.location_snapshot);
  ELSE
    NEW.location_snapshot:=NULL;
    NEW.location_snapshot_hash:=NULL;
  END IF;

  NEW.route_authority_hash:=
    retail.r1b_sha256_jsonb(retail.r1b_route_authority_document(NEW));

  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1b_prepare_route
BEFORE INSERT ON retail.search_route_bindings
FOR EACH ROW EXECUTE FUNCTION retail.r1b_prepare_route();

CREATE OR REPLACE FUNCTION retail.r1b_route_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'R1B routes cannot be deleted; retire them';
  END IF;

  IF (to_jsonb(NEW)-ARRAY[
      'route_status','approved_by','approved_at','updated_at',
      'source_process_run_id','source_correlation_id'
    ]) IS DISTINCT FROM
     (to_jsonb(OLD)-ARRAY[
      'route_status','approved_by','approved_at','updated_at',
      'source_process_run_id','source_correlation_id'
    ]) THEN
    RAISE EXCEPTION 'R1B route authority is immutable; create a new route';
  END IF;

  IF OLD.route_status='retired' AND NEW.route_status IS DISTINCT FROM 'retired' THEN
    RAISE EXCEPTION 'Retired R1B route is terminal';
  END IF;

  IF NEW.route_status IS DISTINCT FROM OLD.route_status THEN
    IF OLD.route_status='draft' AND NEW.route_status NOT IN ('approved','retired') THEN
      RAISE EXCEPTION 'Invalid route transition % -> %',OLD.route_status,NEW.route_status;
    ELSIF OLD.route_status='approved' AND NEW.route_status NOT IN ('paused','retired') THEN
      RAISE EXCEPTION 'Invalid route transition % -> %',OLD.route_status,NEW.route_status;
    ELSIF OLD.route_status='paused' AND NEW.route_status NOT IN ('approved','retired') THEN
      RAISE EXCEPTION 'Invalid route transition % -> %',OLD.route_status,NEW.route_status;
    END IF;
  END IF;

  NEW.updated_at:=now();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1b_route_guard
BEFORE UPDATE OR DELETE ON retail.search_route_bindings
FOR EACH ROW EXECUTE FUNCTION retail.r1b_route_guard();

-- ---------- CURRENTNESS ------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1b_route_is_current(p_route_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      r.route_status='approved'
      AND retail.r1b_r1a_binding_is_current()=true
      AND e.revision_hash=r.r1a_revision_hash
      AND p.status::text='active'
      AND p.is_data_collection_supported=true
      AND s.platform_id=r.platform_id
      AND s.is_approved=true
      AND s.is_active=true
      AND (s.config_id IS NULL OR c.is_active=true)
      AND a.platform_id=r.platform_id
      AND retail.r1b_adapter_is_certified_current(a.id)
      AND (
        a.supports_all_collection_methods=true
        OR (
          jsonb_array_length(a.supported_collection_methods)>0
          AND s.collection_method::text = ANY(
            SELECT jsonb_array_elements_text(a.supported_collection_methods)
          )
        )
      )
      AND (
        a.supports_all_source_types=true
        OR (
          jsonb_array_length(a.supported_source_types)>0
          AND s.source_type = ANY(
            SELECT jsonb_array_elements_text(a.supported_source_types)
          )
        )
      )
      AND (
        r.location_id IS NULL OR l.location_status='approved'
      )
      AND (
        l.id IS NULL OR l.location_type<>'store' OR l.platform_id=r.platform_id
      )
      AND (
        s.source_scope NOT IN ('store','postal_code') OR r.location_id IS NOT NULL
      )
      AND (
        s.required_store_id IS NULL OR l.retailer_store_id IS NOT DISTINCT FROM s.required_store_id
      )
      AND (
        s.required_postal_code IS NULL OR l.postal_code IS NOT DISTINCT FROM s.required_postal_code
      )
      AND (
        l.id IS NULL OR l.location_type<>'store' OR a.supports_store_id=true
      )
      AND (
        l.id IS NULL OR l.location_type<>'postal_code' OR a.supports_postal_code=true
      )
      AND (
        l.id IS NULL OR l.location_type<>'region' OR a.supports_region=true
      )
      AND r.platform_snapshot_hash=
          retail.r1b_sha256_jsonb(retail.r1b_platform_authority_document(r.platform_id))
      AND r.source_snapshot_hash=
          retail.r1b_sha256_jsonb(retail.r1b_source_authority_document(r.collection_source_id))
      AND r.adapter_snapshot_hash=
          retail.r1b_sha256_jsonb(retail.r1b_adapter_authority_document(r.adapter_id))
      AND (
        r.location_id IS NULL
        OR r.location_snapshot_hash=
           retail.r1b_sha256_jsonb(retail.r1b_location_authority_document(r.location_id))
      )
      AND r.route_authority_hash=
          retail.r1b_sha256_jsonb(retail.r1b_route_authority_document(r))
    FROM retail.search_route_bindings r
    JOIN retail.effective_search_targets e
      ON e.target_id=r.target_id AND e.revision_id=r.r1a_revision_id
    JOIN retail.retail_platforms p ON p.id=r.platform_id
    JOIN retail.platform_collection_sources s ON s.id=r.collection_source_id
    LEFT JOIN retail.platform_collection_configs c ON c.id=s.config_id
    JOIN retail.retail_search_adapters a ON a.id=r.adapter_id
    LEFT JOIN retail.search_locations l ON l.id=r.location_id
    WHERE r.id=p_route_id
  ),false)
$$;

-- Sole executable R1B authority. Note: no hard dependence on
-- R1A.desired_source_types; source-type authority is owned here by the
-- selected source + certified adapter capabilities.
CREATE VIEW retail.effective_search_routes AS
SELECT
  r.id AS route_id,
  r.route_code,
  r.route_authority_hash,

  e.target_id,
  e.target_code,
  e.revision_id AS r1a_revision_id,
  e.revision_hash AS r1a_revision_hash,
  e.category_key,
  e.family_key,
  e.family_name,
  e.canonical_product_key,
  e.brand,
  e.model_family,
  e.keyword_fingerprint,
  e.include_terms,
  e.exclude_terms,
  e.allowed_conditions AS allowed_product_conditions,
  e.desired_discount_signals,
  e.discovery_price_ceiling_usd,
  e.discovery_result_limit,
  e.priority_tier,
  e.search_policy,

  p.id AS platform_id,
  p.platform_code,
  p.platform_name,
  p.base_url,

  s.id AS collection_source_id,
  s.source_code,
  s.source_name,
  s.source_url,
  s.source_type,
  s.source_scope,
  s.collection_method,
  s.dataset_id,
  s.unlocker_zone,
  s.request_overrides,
  s.pagination_policy,
  s.qualification_policy,

  a.id AS adapter_id,
  a.adapter_type,
  a.adapter_code,
  a.adapter_version,
  a.implementation_ref,
  a.implementation_sha256,
  a.git_commit_sha,
  a.input_contract_json,
  a.input_contract_sha256,
  a.capability_sha256,
  a.certification_evidence_hash,
  a.certification_fingerprint_hash,
  a.supports_keyword_search,
  a.supports_product_url,
  a.supports_category_search,
  a.supports_store_id,
  a.supports_postal_code,
  a.supports_region,
  a.supports_result_limit,
  a.supports_all_collection_methods,
  a.supports_all_source_types,

  l.id AS location_id,
  l.location_code,
  l.location_type,
  l.country_code,
  l.state_code,
  l.metro_name,
  l.postal_code,
  l.retailer_store_id,
  l.display_name,

  r.platform_snapshot_hash,
  r.source_snapshot_hash,
  r.adapter_snapshot_hash,
  r.location_snapshot_hash,
  r.routing_policy,
  r.source_process_run_id,
  r.source_correlation_id
FROM retail.search_route_bindings r
JOIN retail.effective_search_targets e
  ON e.target_id=r.target_id
 AND e.revision_id=r.r1a_revision_id
 AND e.revision_hash=r.r1a_revision_hash
JOIN retail.retail_platforms p ON p.id=r.platform_id
JOIN retail.platform_collection_sources s ON s.id=r.collection_source_id
LEFT JOIN retail.platform_collection_configs c ON c.id=s.config_id
JOIN retail.retail_search_adapters a ON a.id=r.adapter_id
LEFT JOIN retail.search_locations l ON l.id=r.location_id
WHERE retail.r1b_route_is_current(r.id)=true;

COMMENT ON VIEW retail.effective_search_routes IS
'R1B sole executable route authority for R1C. Never compile from search_route_bindings directly.';

-- ---------- APPROVAL ---------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1b_validate_route_approval()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.route_status='approved' THEN
    IF NEW.approved_by IS NULL OR NEW.approved_at IS NULL THEN
      RAISE EXCEPTION 'Approved route requires approved_by and approved_at';
    END IF;

    IF NOT EXISTS(
      SELECT 1 FROM retail.effective_search_targets e
      WHERE e.target_id=NEW.target_id
        AND e.revision_id=NEW.r1a_revision_id
        AND e.revision_hash=NEW.r1a_revision_hash
    ) THEN
      RAISE EXCEPTION 'Route approval blocked: stale/non-effective R1A revision';
    END IF;

    IF NOT EXISTS(
      SELECT 1 FROM retail.retail_search_adapters a
      WHERE a.id=NEW.adapter_id
        AND a.platform_id=NEW.platform_id
        AND retail.r1b_adapter_is_certified_current(a.id)
    ) THEN
      RAISE EXCEPTION 'Route approval blocked: adapter not currently certified';
    END IF;

    IF NEW.location_id IS NOT NULL AND NOT EXISTS(
      SELECT 1 FROM retail.search_locations l
      WHERE l.id=NEW.location_id
        AND l.location_status='approved'
        AND (l.location_type<>'store' OR l.platform_id=NEW.platform_id)
    ) THEN
      RAISE EXCEPTION 'Route approval blocked: location is not approved/current for platform';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_r1b_validate_route_approval
BEFORE INSERT OR UPDATE OF route_status,approved_by,approved_at
ON retail.search_route_bindings
FOR EACH ROW EXECUTE FUNCTION retail.r1b_validate_route_approval();


-- ---------- ATOMIC AUTHORITY FUNCTIONS --------------------------------------
CREATE OR REPLACE FUNCTION retail.r1b_approve_route(
  p_route_id uuid,
  p_approver text,
  p_process_run_id uuid,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
BEGIN
  IF p_approver IS NULL OR btrim(p_approver)='' THEN
    RAISE EXCEPTION 'Approver required';
  END IF;

  PERFORM set_config('app.actor_type','user',true);
  PERFORM set_config('app.actor_id',p_approver,true);
  PERFORM set_config('app.actor_name',p_approver,true);
  PERFORM set_config('app.process_run_id',p_process_run_id::text,true);
  PERFORM set_config('app.correlation_id',p_correlation_id,true);

  UPDATE retail.search_route_bindings
  SET route_status='approved',
      approved_by=p_approver,
      approved_at=now(),
      source_process_run_id=p_process_run_id,
      source_correlation_id=p_correlation_id
  WHERE id=p_route_id
    AND route_status IN ('draft','paused');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Route missing or not eligible for approval';
  END IF;

  IF retail.r1b_route_is_current(p_route_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Route approval failed closed: route is not currently valid';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION retail.r1b_certify_adapter(
  p_adapter_id uuid,
  p_evidence_sha256 text,
  p_git_commit_sha text,
  p_certifier text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
BEGIN
  IF p_evidence_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Certification evidence SHA-256 invalid';
  END IF;

  UPDATE retail.retail_search_adapters
  SET certification_status='certified_dynamic_search',
      certification_evidence_hash=p_evidence_sha256,
      git_commit_sha=COALESCE(p_git_commit_sha,git_commit_sha),
      certified_by=p_certifier,
      certified_at=now()
  WHERE id=p_adapter_id
    AND certification_status IN ('uncertified','test_only','partially_dynamic');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Adapter missing or not eligible for certification';
  END IF;

  IF retail.r1b_adapter_is_certified_current(p_adapter_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Adapter certification failed closed';
  END IF;
END $$;

-- Application roles should receive EXECUTE on authority functions and SELECT on
-- effective views, not direct UPDATE rights on certification/approval columns.
REVOKE UPDATE(
  certification_status,certification_evidence_hash,certification_fingerprint_hash,
  certified_by,certified_at,implementation_ref,implementation_sha256,
  input_contract_json,input_contract_sha256,capability_json,capability_sha256,
  supports_keyword_search,supports_product_url,supports_category_search,
  supports_store_id,supports_postal_code,supports_region,supports_result_limit,
  supported_collection_methods,supports_all_collection_methods,
  supported_source_types,supports_all_source_types
) ON retail.retail_search_adapters FROM PUBLIC;

REVOKE UPDATE(
  route_status,approved_by,approved_at,platform_id,collection_source_id,
  adapter_id,location_id,r1a_revision_id,r1a_revision_hash,
  platform_snapshot,platform_snapshot_hash,source_snapshot,source_snapshot_hash,
  adapter_snapshot,adapter_snapshot_hash,location_snapshot,location_snapshot_hash,
  route_authority_hash
) ON retail.search_route_bindings FROM PUBLIC;

-- ---------- ACTOR-CORRECT AUDIT ---------------------------------------------
CREATE OR REPLACE FUNCTION retail_audit.r1b_log_retail_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
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
    CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
    CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END,
    v_actor
  );

  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER trg_r1b_audit_locations
AFTER INSERT OR UPDATE OR DELETE ON retail.search_locations
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1b_log_retail_change();

CREATE TRIGGER trg_r1b_audit_adapters
AFTER INSERT OR UPDATE OR DELETE ON retail.retail_search_adapters
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1b_log_retail_change();

CREATE TRIGGER trg_r1b_audit_routes
AFTER INSERT OR UPDATE OR DELETE ON retail.search_route_bindings
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1b_log_retail_change();

COMMIT;
