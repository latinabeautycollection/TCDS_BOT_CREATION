
-- TCDS Retail R1F V2.2 Financial Consumption Hardening
-- Adversarial remediation for V2.1 provider-cost layer.
-- Goals:
--   * causal job<->provider provenance
--   * separation of duties / no direct generic-worker DML
--   * DB-derived raw-payload projections
--   * explicit normalized provider periods with overlap prevention
--   * one authoritative provider cost per R1D job
--   * transaction-safe locking
--   * exact PostgreSQL NUMERIC allocation
--   * zero-cost vs paid-cost semantics
--   * current certified/effective R1D scraper coverage / commit attestation
--   * global hygiene certification

BEGIN;

DO $$
BEGIN
  IF to_regclass('retail.r1f_financial_consumption_state') IS NULL THEN
    RAISE EXCEPTION 'R1F V2.2 financial hardening requires V2.1 financial layer';
  END IF;
  IF to_regclass('retail.r1d_dispatch_jobs') IS NULL
     OR to_regclass('retail.r1d_dispatch_attempts') IS NULL
     OR to_regclass('retail.retail_platforms') IS NULL THEN
    RAISE EXCEPTION 'R1F V2.2 requires R1D dispatch and retail platform authority tables';
  END IF;
END $$;

-- ---------- SEPARATION OF DUTIES --------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1f_financial_registry') THEN
    CREATE ROLE retail_r1f_financial_registry NOLOGIN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1f_financial_collector') THEN
    CREATE ROLE retail_r1f_financial_collector NOLOGIN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='retail_r1f_financial_reconciler') THEN
    CREATE ROLE retail_r1f_financial_reconciler NOLOGIN;
  END IF;
END $$;

REVOKE INSERT,UPDATE,DELETE ON retail.r1f_provider_cost_evidence FROM PUBLIC,retail_r1f_worker;
REVOKE INSERT,UPDATE,DELETE ON retail.r1f_provider_cost_buckets FROM PUBLIC,retail_r1f_worker;
REVOKE INSERT,UPDATE,DELETE ON retail.r1f_provider_job_cost_bindings FROM PUBLIC,retail_r1f_worker;
REVOKE INSERT,UPDATE,DELETE ON retail.r1f_provider_job_cost_reconciliations FROM PUBLIC,retail_r1f_worker;

-- ---------- REPOSITORY + CURRENT R1D SCRAPER AUTHORITY -----------------------

CREATE TABLE retail.r1f_scraper_repository_attestations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_url text NOT NULL,
  branch_name text NOT NULL,
  commit_sha text NOT NULL CHECK(commit_sha ~ '^[0-9a-f]{40}$'),
  discovered_scraper_count integer NOT NULL CHECK(discovered_scraper_count>0),
  expected_scraper_count integer NOT NULL CHECK(expected_scraper_count>0),
  scraper_manifest jsonb NOT NULL CHECK(jsonb_typeof(scraper_manifest)='array'),
  manifest_sha256 text NOT NULL CHECK(manifest_sha256 ~ '^[0-9a-f]{64}$'),
  attestation_document jsonb NOT NULL CHECK(jsonb_typeof(attestation_document)='object'),
  attestation_sha256 text NOT NULL CHECK(attestation_sha256 ~ '^[0-9a-f]{64}$'),
  attested_by text NOT NULL,
  attested_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(repository_url,commit_sha,manifest_sha256),
  CHECK(discovered_scraper_count=expected_scraper_count)
);

CREATE TABLE retail.r1f_scraper_financial_registry(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_attestation_id uuid NOT NULL
    REFERENCES retail.r1f_scraper_repository_attestations(id) ON DELETE RESTRICT,
  scraper_key text NOT NULL CHECK(length(btrim(scraper_key))>0),
  source_path text NOT NULL CHECK(length(btrim(source_path))>0),
  source_sha256 text NOT NULL CHECK(source_sha256 ~ '^[0-9a-f]{64}$'),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  provider text NOT NULL DEFAULT 'BRIGHT_DATA' CHECK(provider='BRIGHT_DATA'),
  provider_product text NOT NULL CHECK(provider_product IN(
    'ZONE_PROXY','WEB_SCRAPER_API','SCRAPER_STUDIO','WEB_UNLOCKER','BROWSER_API','SERP_API'
  )),
  billing_authority text NOT NULL CHECK(billing_authority IN(
    'ZONE_COST','COST_BREAKDOWN'
  )),
  service_type text NOT NULL CHECK(service_type IN(
    'RESIDENTIAL_PROXY','DATACENTER_PROXY','ISP_PROXY','MOBILE_PROXY',
    'UNLOCKER','BROWSER','SERP','WEB_SCRAPER','SCRAPER_STUDIO'
  )),
  zone_name text,
  dataset_id text,
  collector_id text,
  expected_domains jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(expected_domains)='array'),
  financial_identity_document jsonb NOT NULL CHECK(jsonb_typeof(financial_identity_document)='object'),
  financial_identity_sha256 text NOT NULL CHECK(financial_identity_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  registered_by text NOT NULL,
  registered_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(repository_attestation_id,scraper_key),
  UNIQUE(repository_attestation_id,source_path),
  CHECK(
    (billing_authority='ZONE_COST' AND zone_name IS NOT NULL)
    OR
    (billing_authority='COST_BREAKDOWN' AND (dataset_id IS NOT NULL OR collector_id IS NOT NULL))
  )
);

CREATE TABLE retail.r1f_provider_zone_registry(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL DEFAULT 'BRIGHT_DATA' CHECK(provider='BRIGHT_DATA'),
  zone_name text NOT NULL,
  service_type text NOT NULL CHECK(service_type IN(
    'RESIDENTIAL_PROXY','DATACENTER_PROXY','ISP_PROXY','MOBILE_PROXY',
    'UNLOCKER','BROWSER','SERP'
  )),
  billing_authority text NOT NULL CHECK(billing_authority='ZONE_COST'),
  registry_document jsonb NOT NULL CHECK(jsonb_typeof(registry_document)='object'),
  registry_sha256 text NOT NULL CHECK(registry_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  registered_by text NOT NULL,
  registered_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(provider,zone_name)
);

-- ---------- CAUSAL EXECUTION RECEIPTS ---------------------------------------

CREATE TABLE retail.r1f_job_provider_execution_receipts(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  r1d_job_id uuid NOT NULL UNIQUE REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  scraper_registry_id uuid NOT NULL REFERENCES retail.r1f_scraper_financial_registry(id) ON DELETE RESTRICT,
  provider text NOT NULL DEFAULT 'BRIGHT_DATA' CHECK(provider='BRIGHT_DATA'),
  provider_product text NOT NULL,
  billing_authority text NOT NULL,
  service_type text NOT NULL,
  zone_name text,
  dataset_id text,
  collector_id text,
  snapshot_id text,
  provider_request_id text,
  provider_session_id text,
  started_at_utc timestamptz NOT NULL,
  completed_at_utc timestamptz NOT NULL,
  provider_request_count bigint CHECK(provider_request_count IS NULL OR provider_request_count>=0),
  provider_bandwidth_bytes bigint CHECK(provider_bandwidth_bytes IS NULL OR provider_bandwidth_bytes>=0),
  records_requested bigint CHECK(records_requested IS NULL OR records_requested>=0),
  records_collected bigint CHECK(records_collected IS NULL OR records_collected>=0),
  receipt_document jsonb NOT NULL CHECK(jsonb_typeof(receipt_document)='object'),
  receipt_sha256 text NOT NULL CHECK(receipt_sha256 ~ '^[0-9a-f]{64}$'),
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(completed_at_utc>=started_at_utc)
);

CREATE UNIQUE INDEX idx_r1f_execution_receipt_snapshot_one_job
ON retail.r1f_job_provider_execution_receipts(provider,snapshot_id)
WHERE snapshot_id IS NOT NULL;

-- ---------- HARDEN LEGACY PROVIDER EVIDENCE --------------------------------

ALTER TABLE retail.r1f_provider_cost_evidence
  ADD COLUMN IF NOT EXISTS evidence_version text NOT NULL DEFAULT 'V2.1',
  ADD COLUMN IF NOT EXISTS transport_verified boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS request_fingerprint_verified boolean NOT NULL DEFAULT false;

ALTER TABLE retail.r1f_provider_cost_buckets
  ADD COLUMN IF NOT EXISTS provider_period_start timestamptz,
  ADD COLUMN IF NOT EXISTS provider_period_end_exclusive timestamptz,
  ADD COLUMN IF NOT EXISTS provider_period_type text,
  ADD COLUMN IF NOT EXISTS provider_scope_key text,
  ADD COLUMN IF NOT EXISTS projection_verified boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS financial_authority_state text NOT NULL DEFAULT 'USAGE_ONLY_PENDING_SEMANTICS';

ALTER TABLE retail.r1f_provider_job_cost_bindings
  ADD COLUMN IF NOT EXISTS execution_receipt_id uuid
    REFERENCES retail.r1f_job_provider_execution_receipts(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS scraper_registry_id uuid
    REFERENCES retail.r1f_scraper_financial_registry(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS attribution_confidence text,
  ADD COLUMN IF NOT EXISTS binding_version text NOT NULL DEFAULT 'V2.1';

ALTER TABLE retail.r1f_provider_job_cost_reconciliations
  ADD COLUMN IF NOT EXISTS execution_receipt_id uuid
    REFERENCES retail.r1f_job_provider_execution_receipts(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS scraper_registry_id uuid
    REFERENCES retail.r1f_scraper_financial_registry(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS usage_verification_status text,
  ADD COLUMN IF NOT EXISTS financial_verification_status text,
  ADD COLUMN IF NOT EXISTS reconciliation_version text NOT NULL DEFAULT 'V2.1';

-- Old V2.1 normalized buckets are not automatically promoted to V2.2 authority.
UPDATE retail.r1f_provider_cost_buckets b
SET provider_period_start=e.period_from::timestamptz,
    provider_period_end_exclusive=e.period_to_exclusive::timestamptz,
    provider_period_type='OPAQUE_PROVIDER_SUMMARY',
    provider_scope_key='BRIGHT_DATA:'||e.zone_name||':'||b.bucket_key,
    projection_verified=false,
    financial_authority_state='USAGE_ONLY_PENDING_SEMANTICS'
FROM retail.r1f_provider_cost_evidence e
WHERE e.id=b.evidence_id
  AND b.provider_period_start IS NULL;


-- ---------- BRIGHT DATA COST BREAKDOWN EVIDENCE ------------------------------

CREATE TABLE retail.r1f_provider_cost_breakdown_evidence(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL DEFAULT 'BRIGHT_DATA' CHECK(provider='BRIGHT_DATA'),
  source_endpoint text NOT NULL DEFAULT '/costs/export/json'
    CHECK(source_endpoint='/costs/export/json'),
  dimension text NOT NULL CHECK(dimension IN(
    'web_apis','collectors','ws_api_snaps','products','types','zones','datasets','domains','snapshots'
  )),
  period_from date NOT NULL,
  period_to_exclusive date NOT NULL,
  http_status integer NOT NULL CHECK(http_status BETWEEN 200 AND 299),
  raw_payload jsonb NOT NULL CHECK(jsonb_typeof(raw_payload)='object'),
  raw_payload_sha256 text NOT NULL CHECK(raw_payload_sha256 ~ '^[0-9a-f]{64}$'),
  request_fingerprint_sha256 text NOT NULL CHECK(request_fingerprint_sha256 ~ '^[0-9a-f]{64}$'),
  transport_verified boolean NOT NULL DEFAULT true,
  request_fingerprint_verified boolean NOT NULL DEFAULT true,
  source_process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text,
  retrieved_at timestamptz NOT NULL DEFAULT now(),
  CHECK(period_to_exclusive>period_from),
  UNIQUE(dimension,period_from,period_to_exclusive,raw_payload_sha256)
);

CREATE TABLE retail.r1f_provider_daily_resource_costs(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_id uuid NOT NULL
    REFERENCES retail.r1f_provider_cost_breakdown_evidence(id) ON DELETE RESTRICT,
  cost_day date NOT NULL,
  dimension text NOT NULL,
  resource_id text NOT NULL CHECK(length(btrim(resource_id))>0),
  billed_cost_usd numeric(18,8) NOT NULL CHECK(billed_cost_usd>=0),
  resource_document jsonb NOT NULL CHECK(jsonb_typeof(resource_document)='object'),
  resource_sha256 text NOT NULL CHECK(resource_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(evidence_id,cost_day,resource_id)
);

-- ---------- NORMALIZED PROVIDER PERIOD AUTHORITY ----------------------------

CREATE TABLE retail.r1f_provider_cost_authority_periods(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  authority_source_type text NOT NULL CHECK(authority_source_type IN('ZONE_COST','COST_BREAKDOWN')),
  evidence_id uuid REFERENCES retail.r1f_provider_cost_evidence(id) ON DELETE RESTRICT,
  bucket_id uuid REFERENCES retail.r1f_provider_cost_buckets(id) ON DELETE RESTRICT,
  cost_breakdown_evidence_id uuid
    REFERENCES retail.r1f_provider_cost_breakdown_evidence(id) ON DELETE RESTRICT,
  daily_resource_cost_id uuid
    REFERENCES retail.r1f_provider_daily_resource_costs(id) ON DELETE RESTRICT,
  provider text NOT NULL DEFAULT 'BRIGHT_DATA' CHECK(provider='BRIGHT_DATA'),
  service_type text NOT NULL,
  zone_name text,
  provider_dimension text,
  provider_resource_id text,
  provider_period_start timestamptz NOT NULL,
  provider_period_end_exclusive timestamptz NOT NULL,
  provider_period_type text NOT NULL CHECK(provider_period_type IN(
    'CALENDAR_DAY','CALENDAR_MONTH','EXACT_REQUEST_RANGE'
  )),
  provider_scope_key text NOT NULL,
  billed_cost_usd numeric(18,8) NOT NULL CHECK(billed_cost_usd>=0),
  bandwidth_bytes bigint CHECK(bandwidth_bytes IS NULL OR bandwidth_bytes>=0),
  bucket_key text,
  semantics_evidence jsonb NOT NULL CHECK(jsonb_typeof(semantics_evidence)='object'),
  semantics_sha256 text NOT NULL CHECK(semantics_sha256 ~ '^[0-9a-f]{64}$'),
  authority_document jsonb NOT NULL CHECK(jsonb_typeof(authority_document)='object'),
  authority_sha256 text NOT NULL CHECK(authority_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  promoted_by text NOT NULL,
  promoted_at timestamptz NOT NULL DEFAULT now(),
  CHECK(provider_period_end_exclusive>provider_period_start),
  CHECK(
    (authority_source_type='ZONE_COST'
      AND evidence_id IS NOT NULL AND bucket_id IS NOT NULL
      AND cost_breakdown_evidence_id IS NULL AND daily_resource_cost_id IS NULL
      AND zone_name IS NOT NULL AND bucket_key IS NOT NULL)
    OR
    (authority_source_type='COST_BREAKDOWN'
      AND evidence_id IS NULL AND bucket_id IS NULL
      AND cost_breakdown_evidence_id IS NOT NULL AND daily_resource_cost_id IS NOT NULL
      AND provider_dimension IS NOT NULL AND provider_resource_id IS NOT NULL)
  )
);

CREATE INDEX idx_r1f_provider_authority_scope_period
ON retail.r1f_provider_cost_authority_periods(
  provider,provider_scope_key,provider_period_start,provider_period_end_exclusive
) WHERE active=true;

-- ---------- V2.2 BINDINGS + EXACT ALLOCATIONS -------------------------------

CREATE TABLE retail.r1f_provider_job_cost_bindings_v22(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  authority_period_id uuid NOT NULL
    REFERENCES retail.r1f_provider_cost_authority_periods(id) ON DELETE RESTRICT,
  r1d_job_id uuid NOT NULL UNIQUE REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  execution_receipt_id uuid NOT NULL UNIQUE
    REFERENCES retail.r1f_job_provider_execution_receipts(id) ON DELETE RESTRICT,
  scraper_registry_id uuid NOT NULL
    REFERENCES retail.r1f_scraper_financial_registry(id) ON DELETE RESTRICT,
  attribution_basis text NOT NULL CHECK(attribution_basis IN(
    'DIRECT_RESOURCE','PROVIDER_BYTES','PROVIDER_REQUESTS',
    'RECORDS_COLLECTED','RECORDS_REQUESTED','EQUAL_SHARE','EXPLICIT_WEIGHT'
  )),
  attribution_weight numeric(30,8) NOT NULL CHECK(attribution_weight>0),
  attribution_confidence text NOT NULL CHECK(attribution_confidence IN(
    'DIRECT_CAUSAL','HIGH','MEDIUM','ALLOCATED_NON_CAUSAL'
  )),
  binding_document jsonb NOT NULL CHECK(jsonb_typeof(binding_document)='object'),
  binding_sha256 text NOT NULL CHECK(binding_sha256 ~ '^[0-9a-f]{64}$'),
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE retail.r1f_provider_job_cost_allocations_v22(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  authority_period_id uuid NOT NULL
    REFERENCES retail.r1f_provider_cost_authority_periods(id) ON DELETE RESTRICT,
  binding_id uuid NOT NULL UNIQUE
    REFERENCES retail.r1f_provider_job_cost_bindings_v22(id) ON DELETE RESTRICT,
  r1d_job_id uuid NOT NULL UNIQUE REFERENCES retail.r1d_dispatch_jobs(id) ON DELETE RESTRICT,
  execution_receipt_id uuid NOT NULL
    REFERENCES retail.r1f_job_provider_execution_receipts(id) ON DELETE RESTRICT,
  scraper_registry_id uuid NOT NULL
    REFERENCES retail.r1f_scraper_financial_registry(id) ON DELETE RESTRICT,
  provider_billed_cost_usd numeric(18,8) NOT NULL CHECK(provider_billed_cost_usd>=0),
  provider_bandwidth_bytes bigint CHECK(provider_bandwidth_bytes IS NULL OR provider_bandwidth_bytes>=0),
  allocation_numerator numeric(30,8) NOT NULL CHECK(allocation_numerator>0),
  allocation_denominator numeric(30,8) NOT NULL CHECK(allocation_denominator>0),
  allocated_provider_cost_usd numeric(18,8) NOT NULL CHECK(allocated_provider_cost_usd>=0),
  attribution_method text NOT NULL,
  attribution_confidence text NOT NULL,
  usage_verification_status text NOT NULL CHECK(usage_verification_status IN(
    'PROVIDER_USAGE_CONFIRMED','PROVIDER_USAGE_ZERO','PROVIDER_USAGE_UNVERIFIED'
  )),
  financial_verification_status text NOT NULL CHECK(financial_verification_status IN(
    'PROVIDER_PAID_COST_RECONCILED','PROVIDER_ZERO_COST_CONFIRMED'
  )),
  allocation_document jsonb NOT NULL CHECK(jsonb_typeof(allocation_document)='object'),
  allocation_sha256 text NOT NULL CHECK(allocation_sha256 ~ '^[0-9a-f]{64}$'),
  reconciled_by text NOT NULL,
  reconciled_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- IMMUTABILITY -----------------------------------------------------

CREATE OR REPLACE FUNCTION retail.r1f_financial_v22_append_only_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'R1F V2.2 financial authority rows are append-only';
END $$;

CREATE TRIGGER trg_r1f_cost_breakdown_evidence_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_provider_cost_breakdown_evidence
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_v22_append_only_guard();

CREATE TRIGGER trg_r1f_daily_resource_cost_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_provider_daily_resource_costs
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_v22_append_only_guard();

CREATE TRIGGER trg_r1f_repo_attestation_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_scraper_repository_attestations
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_v22_append_only_guard();

CREATE TRIGGER trg_r1f_scraper_registry_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_scraper_financial_registry
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_v22_append_only_guard();

CREATE TRIGGER trg_r1f_provider_zone_registry_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_provider_zone_registry
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_v22_append_only_guard();

CREATE TRIGGER trg_r1f_job_receipt_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_job_provider_execution_receipts
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_v22_append_only_guard();

CREATE TRIGGER trg_r1f_authority_period_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_provider_cost_authority_periods
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_v22_append_only_guard();

CREATE TRIGGER trg_r1f_binding_v22_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_provider_job_cost_bindings_v22
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_v22_append_only_guard();

CREATE TRIGGER trg_r1f_allocation_v22_immutable
BEFORE UPDATE OR DELETE ON retail.r1f_provider_job_cost_allocations_v22
FOR EACH ROW EXECUTE FUNCTION retail.r1f_financial_v22_append_only_guard();

-- ---------- SCRAPER / REPOSITORY REGISTRATION FUNCTIONS ---------------------

CREATE OR REPLACE FUNCTION retail.r1f_register_scraper_repository_attestation(
  p_repository_url text,
  p_branch_name text,
  p_commit_sha text,
  p_scraper_manifest jsonb,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_count integer;
  v_expected_count integer;
  v_doc jsonb;
  v_id uuid;
BEGIN
  IF session_user NOT IN ('retail_r1f_financial_registry') AND NOT pg_has_role(session_user,'retail_r1f_financial_registry','member') THEN
    RAISE EXCEPTION 'R1F financial registry authority required';
  END IF;
  IF p_commit_sha !~ '^[0-9a-f]{40}$' THEN
    RAISE EXCEPTION 'repository commit SHA must be full 40-char lowercase SHA-1';
  END IF;
  IF jsonb_typeof(p_scraper_manifest)<>'array' THEN
    RAISE EXCEPTION 'scraper manifest must be array';
  END IF;
  v_count:=jsonb_array_length(p_scraper_manifest);
  SELECT count(distinct ec.adapter_id)::int
  INTO v_expected_count
  FROM retail.effective_compiled_search_jobs ec
  WHERE EXISTS(
    SELECT 1
    FROM retail.r1d_dispatch_bindings binding
    WHERE binding.adapter_id=ec.adapter_id
      AND retail.r1d_dispatch_binding_is_current(binding.id)=true
  );
  IF v_expected_count=0 THEN
    RAISE EXCEPTION 'R1F V2.2 requires non-empty current R1D scraper authority';
  END IF;
  IF v_count<>v_expected_count THEN
    RAISE EXCEPTION
      'R1F V2.2 manifest count % does not match current R1D scraper scope %',
      v_count,v_expected_count;
  END IF;
  IF EXISTS(
    SELECT 1
    FROM retail.effective_compiled_search_jobs ec
    WHERE EXISTS(
      SELECT 1 FROM retail.r1d_dispatch_bindings binding
      WHERE binding.adapter_id=ec.adapter_id
        AND retail.r1d_dispatch_binding_is_current(binding.id)=true
    )
      AND NOT EXISTS(
        SELECT 1 FROM jsonb_array_elements(p_scraper_manifest) manifest
        WHERE nullif(manifest->>'adapterId','')=ec.adapter_id::text
      )
  ) OR EXISTS(
    SELECT 1
    FROM jsonb_array_elements(p_scraper_manifest) manifest
    WHERE NOT EXISTS(
      SELECT 1
      FROM retail.effective_compiled_search_jobs ec
      WHERE ec.adapter_id=(manifest->>'adapterId')::uuid
        AND EXISTS(
          SELECT 1 FROM retail.r1d_dispatch_bindings binding
          WHERE binding.adapter_id=ec.adapter_id
            AND retail.r1d_dispatch_binding_is_current(binding.id)=true
        )
    )
  ) THEN
    RAISE EXCEPTION 'manifest does not exactly match current certified/effective R1D adapter scope';
  END IF;
  v_doc:=jsonb_build_object(
    'repository_url',p_repository_url,
    'branch_name',p_branch_name,
    'commit_sha',p_commit_sha,
    'expected_scraper_count',v_expected_count,
    'discovered_scraper_count',v_count,
    'manifest_sha256',retail.r1f_sha256_jsonb(p_scraper_manifest)
  );
  INSERT INTO retail.r1f_scraper_repository_attestations(
    repository_url,branch_name,commit_sha,
    discovered_scraper_count,expected_scraper_count,
    scraper_manifest,manifest_sha256,
    attestation_document,attestation_sha256,attested_by
  ) VALUES(
    p_repository_url,p_branch_name,p_commit_sha,
    v_count,v_expected_count,p_scraper_manifest,retail.r1f_sha256_jsonb(p_scraper_manifest),
    v_doc,retail.r1f_sha256_jsonb(v_doc),p_actor
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_register_scraper_financial_identity(
  p_repository_attestation_id uuid,
  p_scraper_key text,
  p_source_path text,
  p_source_sha256 text,
  p_platform_id uuid,
  p_provider_product text,
  p_billing_authority text,
  p_service_type text,
  p_zone_name text,
  p_dataset_id text,
  p_collector_id text,
  p_expected_domains jsonb,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_doc jsonb;
  v_id uuid;
BEGIN
  IF session_user NOT IN ('retail_r1f_financial_registry') AND NOT pg_has_role(session_user,'retail_r1f_financial_registry','member') THEN
    RAISE EXCEPTION 'R1F financial registry authority required';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM retail.r1f_scraper_repository_attestations a
    WHERE a.id=p_repository_attestation_id
      AND a.discovered_scraper_count=a.expected_scraper_count
  ) THEN
    RAISE EXCEPTION 'valid current-scope scraper repository attestation required';
  END IF;
  IF p_source_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'source SHA-256 invalid';
  END IF;
  IF NOT EXISTS(
    SELECT 1
    FROM retail.r1f_scraper_repository_attestations a
    CROSS JOIN LATERAL jsonb_array_elements(a.scraper_manifest) m
    WHERE a.id=p_repository_attestation_id
      AND m->>'scraperKey'=p_scraper_key
      AND m->>'sourcePath'=p_source_path
      AND m->>'sourceSha256'=p_source_sha256
      AND nullif(m->>'platformId','')=p_platform_id::text
      AND nullif(m->>'providerProduct','')=p_provider_product
      AND nullif(m->>'billingAuthority','')=p_billing_authority
      AND nullif(m->>'serviceType','')=p_service_type
      AND coalesce(nullif(m->>'zoneName',''),'')=coalesce(nullif(btrim(p_zone_name),''),'')
      AND coalesce(nullif(m->>'datasetId',''),'')=coalesce(nullif(btrim(p_dataset_id),''),'')
      AND coalesce(nullif(m->>'collectorId',''),'')=coalesce(nullif(btrim(p_collector_id),''),'')
      AND coalesce(m->'expectedDomains','[]'::jsonb)=coalesce(p_expected_domains,'[]'::jsonb)
  ) THEN
    RAISE EXCEPTION 'scraper financial identity does not exactly match commit-bound repository manifest';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM retail.retail_platforms p WHERE p.id=p_platform_id) THEN
    RAISE EXCEPTION 'platform_id is not authoritative';
  END IF;

  v_doc:=jsonb_build_object(
    'repository_attestation_id',p_repository_attestation_id,
    'scraper_key',p_scraper_key,
    'source_path',p_source_path,
    'source_sha256',p_source_sha256,
    'platform_id',p_platform_id,
    'provider','BRIGHT_DATA',
    'provider_product',p_provider_product,
    'billing_authority',p_billing_authority,
    'service_type',p_service_type,
    'zone_name',p_zone_name,
    'dataset_id',p_dataset_id,
    'collector_id',p_collector_id,
    'expected_domains',coalesce(p_expected_domains,'[]'::jsonb)
  );

  INSERT INTO retail.r1f_scraper_financial_registry(
    repository_attestation_id,scraper_key,source_path,source_sha256,platform_id,
    provider,provider_product,billing_authority,service_type,
    zone_name,dataset_id,collector_id,expected_domains,
    financial_identity_document,financial_identity_sha256,registered_by
  ) VALUES(
    p_repository_attestation_id,p_scraper_key,p_source_path,p_source_sha256,p_platform_id,
    'BRIGHT_DATA',p_provider_product,p_billing_authority,p_service_type,
    nullif(btrim(p_zone_name),''),
    nullif(btrim(p_dataset_id),''),
    nullif(btrim(p_collector_id),''),
    coalesce(p_expected_domains,'[]'::jsonb),
    v_doc,retail.r1f_sha256_jsonb(v_doc),p_actor
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION retail.r1f_register_provider_zone(
  p_zone_name text,
  p_service_type text,
  p_billing_authority text,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_doc jsonb;
  v_id uuid;
BEGIN
  IF session_user NOT IN ('retail_r1f_financial_registry') AND NOT pg_has_role(session_user,'retail_r1f_financial_registry','member') THEN
    RAISE EXCEPTION 'R1F financial registry authority required';
  END IF;
  v_doc:=jsonb_build_object(
    'provider','BRIGHT_DATA',
    'zone_name',p_zone_name,
    'service_type',p_service_type,
    'billing_authority',p_billing_authority
  );
  INSERT INTO retail.r1f_provider_zone_registry(
    provider,zone_name,service_type,billing_authority,
    registry_document,registry_sha256,registered_by
  ) VALUES(
    'BRIGHT_DATA',p_zone_name,p_service_type,p_billing_authority,
    v_doc,retail.r1f_sha256_jsonb(v_doc),p_actor
  ) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------- CAUSAL RECEIPT FUNCTION -----------------------------------------

CREATE OR REPLACE FUNCTION retail.r1f_record_job_provider_execution_receipt(
  p_r1d_job_id uuid,
  p_scraper_key text,
  p_provider_product text,
  p_zone_name text,
  p_dataset_id text,
  p_collector_id text,
  p_snapshot_id text,
  p_provider_request_id text,
  p_provider_session_id text,
  p_started_at_utc timestamptz,
  p_completed_at_utc timestamptz,
  p_provider_request_count bigint,
  p_provider_bandwidth_bytes bigint,
  p_records_requested bigint,
  p_records_collected bigint,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_reg retail.r1f_scraper_financial_registry%ROWTYPE;
  v_job retail.r1d_dispatch_jobs%ROWTYPE;
  v_successes integer;
  v_doc jsonb;
  v_id uuid;
BEGIN
  IF session_user NOT IN ('retail_r1f_worker') AND NOT pg_has_role(session_user,'retail_r1f_worker','member') THEN
    RAISE EXCEPTION 'R1F worker authority required to record execution receipt';
  END IF;

  SELECT * INTO v_job
  FROM retail.r1d_dispatch_jobs
  WHERE id=p_r1d_job_id AND status='succeeded';
  IF NOT FOUND THEN RAISE EXCEPTION 'succeeded R1D job required'; END IF;

  SELECT count(*)::int INTO v_successes
  FROM retail.r1d_dispatch_attempts
  WHERE job_id=p_r1d_job_id AND success=true;
  IF v_successes<>1 THEN
    RAISE EXCEPTION 'exactly one successful R1D attempt required, got %',v_successes;
  END IF;

  SELECT r.* INTO v_reg
  FROM retail.r1f_scraper_financial_registry r
  JOIN retail.r1f_scraper_repository_attestations a ON a.id=r.repository_attestation_id
  WHERE r.scraper_key=p_scraper_key AND r.active=true
    AND a.discovered_scraper_count=a.expected_scraper_count
  ORDER BY a.attested_at DESC
  LIMIT 1;

  IF NOT FOUND THEN RAISE EXCEPTION 'active certified scraper identity not found'; END IF;
  IF v_reg.platform_id IS DISTINCT FROM v_job.platform_id THEN
    RAISE EXCEPTION 'job platform does not match scraper financial registry';
  END IF;
  IF v_reg.provider_product<>p_provider_product THEN
    RAISE EXCEPTION 'provider product mismatch';
  END IF;
  IF v_reg.zone_name IS DISTINCT FROM nullif(btrim(p_zone_name),'') THEN
    RAISE EXCEPTION 'zone mismatch against scraper financial registry';
  END IF;
  IF v_reg.dataset_id IS DISTINCT FROM nullif(btrim(p_dataset_id),'') THEN
    RAISE EXCEPTION 'dataset mismatch against scraper financial registry';
  END IF;
  IF v_reg.collector_id IS DISTINCT FROM nullif(btrim(p_collector_id),'') THEN
    RAISE EXCEPTION 'collector mismatch against scraper financial registry';
  END IF;
  IF p_completed_at_utc<p_started_at_utc THEN
    RAISE EXCEPTION 'execution receipt completed before started';
  END IF;

  v_doc:=jsonb_build_object(
    'r1d_job_id',p_r1d_job_id,
    'scraper_registry_id',v_reg.id,
    'scraper_key',v_reg.scraper_key,
    'provider','BRIGHT_DATA',
    'provider_product',v_reg.provider_product,
    'billing_authority',v_reg.billing_authority,
    'service_type',v_reg.service_type,
    'zone_name',v_reg.zone_name,
    'dataset_id',v_reg.dataset_id,
    'collector_id',v_reg.collector_id,
    'snapshot_id',nullif(btrim(p_snapshot_id),''),
    'provider_request_id',nullif(btrim(p_provider_request_id),''),
    'provider_session_id',nullif(btrim(p_provider_session_id),''),
    'started_at_utc',p_started_at_utc,
    'completed_at_utc',p_completed_at_utc,
    'provider_request_count',p_provider_request_count,
    'provider_bandwidth_bytes',p_provider_bandwidth_bytes,
    'records_requested',p_records_requested,
    'records_collected',p_records_collected
  );

  INSERT INTO retail.r1f_job_provider_execution_receipts(
    r1d_job_id,scraper_registry_id,provider,provider_product,billing_authority,service_type,
    zone_name,dataset_id,collector_id,snapshot_id,provider_request_id,provider_session_id,
    started_at_utc,completed_at_utc,provider_request_count,provider_bandwidth_bytes,
    records_requested,records_collected,receipt_document,receipt_sha256,created_by
  ) VALUES(
    p_r1d_job_id,v_reg.id,'BRIGHT_DATA',v_reg.provider_product,v_reg.billing_authority,v_reg.service_type,
    v_reg.zone_name,v_reg.dataset_id,v_reg.collector_id,
    nullif(btrim(p_snapshot_id),''),nullif(btrim(p_provider_request_id),''),
    nullif(btrim(p_provider_session_id),''),
    p_started_at_utc,p_completed_at_utc,p_provider_request_count,p_provider_bandwidth_bytes,
    p_records_requested,p_records_collected,v_doc,retail.r1f_sha256_jsonb(v_doc),p_actor
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

-- ---------- PROVIDER RESPONSE INGESTION -------------------------------------

CREATE OR REPLACE FUNCTION retail.r1f_record_brightdata_zone_cost_response(
  p_zone_name text,
  p_period_from date,
  p_period_to_exclusive date,
  p_http_status integer,
  p_raw_payload jsonb,
  p_source_process_run_id uuid,
  p_source_correlation_id text,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_zone retail.r1f_provider_zone_registry%ROWTYPE;
  v_evidence_id uuid;
  v_request_doc jsonb;
  v_request_fp text;
  v_bucket record;
  v_bucket_doc jsonb;
  v_payload_root_key text;
  v_payload_root_count integer;
BEGIN
  IF session_user NOT IN ('retail_r1f_financial_collector') AND NOT pg_has_role(session_user,'retail_r1f_financial_collector','member') THEN
    RAISE EXCEPTION 'R1F financial collector authority required';
  END IF;
  IF p_period_to_exclusive<=p_period_from THEN RAISE EXCEPTION 'invalid exclusive date range'; END IF;
  IF p_http_status<200 OR p_http_status>299 THEN RAISE EXCEPTION 'successful Bright Data response required'; END IF;
  IF jsonb_typeof(p_raw_payload)<>'object' THEN
    RAISE EXCEPTION 'Bright Data /zone/cost payload must be an object';
  END IF;
  IF jsonb_typeof(p_raw_payload->'ID')='object' THEN
    v_payload_root_key:='ID';
  ELSE
    SELECT count(*)::int,min(key)
    INTO v_payload_root_count,v_payload_root_key
    FROM jsonb_each(p_raw_payload)
    WHERE jsonb_typeof(value)='object';
    IF v_payload_root_count<>1 THEN
      RAISE EXCEPTION
        'Bright Data /zone/cost payload requires ID or one dynamic account object';
    END IF;
  END IF;

  SELECT * INTO v_zone
  FROM retail.r1f_provider_zone_registry
  WHERE provider='BRIGHT_DATA' AND zone_name=p_zone_name AND active=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'zone not registered for R1F financial authority'; END IF;

  v_request_doc:=jsonb_build_object(
    'endpoint','/zone/cost',
    'zone',p_zone_name,
    'from',p_period_from,
    'toExclusive',p_period_to_exclusive
  );
  v_request_fp:=retail.r1f_sha256_jsonb(v_request_doc);

  INSERT INTO retail.r1f_provider_cost_evidence(
    provider,service_type,source_endpoint,zone_name,
    period_from,period_to_exclusive,http_status,authoritative_for_billing,
    raw_payload,raw_payload_sha256,request_fingerprint_sha256,
    source_process_run_id,source_correlation_id,
    evidence_version,transport_verified,request_fingerprint_verified
  ) VALUES(
    'BRIGHT_DATA',v_zone.service_type,'/zone/cost',p_zone_name,
    p_period_from,p_period_to_exclusive,p_http_status,true,
    p_raw_payload,retail.r1f_sha256_jsonb(p_raw_payload),v_request_fp,
    p_source_process_run_id,p_source_correlation_id,
    'V2.2',true,true
  )
  ON CONFLICT(provider,zone_name,period_from,period_to_exclusive,raw_payload_sha256)
  DO NOTHING
  RETURNING id INTO v_evidence_id;

  IF v_evidence_id IS NULL THEN
    SELECT id INTO v_evidence_id
    FROM retail.r1f_provider_cost_evidence
    WHERE provider='BRIGHT_DATA' AND zone_name=p_zone_name
      AND period_from=p_period_from AND period_to_exclusive=p_period_to_exclusive
      AND raw_payload_sha256=retail.r1f_sha256_jsonb(p_raw_payload);
  END IF;

  FOR v_bucket IN
    SELECT key, value
    FROM jsonb_each(p_raw_payload->v_payload_root_key)
  LOOP
    IF jsonb_typeof(v_bucket.value)<>'object'
       OR NOT (v_bucket.value ? 'bw')
       OR NOT (v_bucket.value ? 'cost') THEN
      RAISE EXCEPTION 'Bright Data bucket % missing bw/cost fields',v_bucket.key;
    END IF;
    v_bucket_doc:=jsonb_build_object(
      'bucketKey',v_bucket.key,
      'providerAccountKey',v_payload_root_key,
      'bandwidthBytes',(v_bucket.value->>'bw')::bigint,
      'billedCostUsd',(v_bucket.value->>'cost')::numeric,
      'raw',v_bucket.value,
      'providerPayloadSha256',retail.r1f_sha256_jsonb(p_raw_payload)
    );

    INSERT INTO retail.r1f_provider_cost_buckets(
      evidence_id,bucket_key,bandwidth_bytes,billed_cost_usd,
      bucket_document,bucket_sha256,
      provider_period_start,provider_period_end_exclusive,provider_period_type,
      provider_scope_key,projection_verified,financial_authority_state
    ) VALUES(
      v_evidence_id,v_bucket.key,
      (v_bucket.value->>'bw')::bigint,
      (v_bucket.value->>'cost')::numeric,
      v_bucket_doc,retail.r1f_sha256_jsonb(v_bucket_doc),
      p_period_from::timestamptz,p_period_to_exclusive::timestamptz,
      'OPAQUE_PROVIDER_SUMMARY',
      'BRIGHT_DATA:'||p_zone_name||':'||v_bucket.key,
      true,'USAGE_ONLY_PENDING_SEMANTICS'
    )
    ON CONFLICT(evidence_id,bucket_key) DO NOTHING;
  END LOOP;

  RETURN v_evidence_id;
END $$;


CREATE OR REPLACE FUNCTION retail.r1f_record_brightdata_cost_breakdown_response(
  p_dimension text,
  p_period_from date,
  p_period_to_exclusive date,
  p_http_status integer,
  p_raw_payload jsonb,
  p_source_process_run_id uuid,
  p_source_correlation_id text,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_evidence_id uuid;
  v_request_doc jsonb;
  v_request_fp text;
  v_day record;
  v_resource record;
  v_day_date date;
  v_cost numeric(18,8);
  v_doc jsonb;
  v_resource_id uuid;
  v_service_type text;
  v_scope text;
  v_authority_doc jsonb;
  v_existing uuid;
  v_existing_cost numeric(18,8);
  v_daily_total numeric(18,8);
  v_declared_total numeric(18,8);
BEGIN
  IF session_user NOT IN ('retail_r1f_financial_collector') AND NOT pg_has_role(session_user,'retail_r1f_financial_collector','member') THEN
    RAISE EXCEPTION 'R1F financial collector authority required';
  END IF;
  IF p_dimension NOT IN('web_apis','collectors','ws_api_snaps') THEN
    RAISE EXCEPTION 'R1F V2.2 cost-breakdown collector supports web_apis, collectors, ws_api_snaps only';
  END IF;
  IF p_period_to_exclusive<=p_period_from THEN RAISE EXCEPTION 'invalid exclusive date range'; END IF;
  IF p_http_status<200 OR p_http_status>299 THEN RAISE EXCEPTION 'successful Bright Data response required'; END IF;
  IF jsonb_typeof(p_raw_payload)<>'object' THEN
    RAISE EXCEPTION 'Bright Data cost breakdown payload must be object';
  END IF;
  IF p_raw_payload ? 'total'
     AND jsonb_typeof(p_raw_payload->'total')<>'object' THEN
    RAISE EXCEPTION 'Bright Data cost breakdown total must be an object';
  END IF;

  v_request_doc:=jsonb_build_object(
    'endpoint','/costs/export/json',
    'dimension',p_dimension,
    'filters',jsonb_build_object(),
    'from',p_period_from,
    'toExclusive',p_period_to_exclusive
  );
  v_request_fp:=retail.r1f_sha256_jsonb(v_request_doc);

  INSERT INTO retail.r1f_provider_cost_breakdown_evidence(
    provider,source_endpoint,dimension,period_from,period_to_exclusive,http_status,
    raw_payload,raw_payload_sha256,request_fingerprint_sha256,
    transport_verified,request_fingerprint_verified,
    source_process_run_id,source_correlation_id
  ) VALUES(
    'BRIGHT_DATA','/costs/export/json',p_dimension,p_period_from,p_period_to_exclusive,p_http_status,
    p_raw_payload,retail.r1f_sha256_jsonb(p_raw_payload),v_request_fp,
    true,true,p_source_process_run_id,p_source_correlation_id
  )
  ON CONFLICT(dimension,period_from,period_to_exclusive,raw_payload_sha256)
  DO NOTHING
  RETURNING id INTO v_evidence_id;

  IF v_evidence_id IS NULL THEN
    SELECT id INTO v_evidence_id
    FROM retail.r1f_provider_cost_breakdown_evidence
    WHERE dimension=p_dimension
      AND period_from=p_period_from
      AND period_to_exclusive=p_period_to_exclusive
      AND raw_payload_sha256=retail.r1f_sha256_jsonb(p_raw_payload);
  END IF;

  v_service_type:=CASE p_dimension
    WHEN 'collectors' THEN 'SCRAPER_STUDIO'
    ELSE 'WEB_SCRAPER'
  END;

  FOR v_day IN
    SELECT key,value FROM jsonb_each(p_raw_payload) WHERE key<>'total'
  LOOP
    BEGIN
      v_day_date:=v_day.key::date;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'invalid cost-breakdown day key %',v_day.key;
    END;
    IF v_day_date<p_period_from OR v_day_date>=p_period_to_exclusive THEN
      RAISE EXCEPTION 'cost-breakdown day % outside requested UTC range',v_day_date;
    END IF;
    IF jsonb_typeof(v_day.value)<>'object' THEN
      RAISE EXCEPTION 'cost-breakdown day % must map resource IDs to billed USD',v_day_date;
    END IF;

    FOR v_resource IN SELECT key,value FROM jsonb_each(v_day.value)
    LOOP
      v_cost:=(v_resource.value #>> '{}')::numeric;
      IF v_cost<0 THEN RAISE EXCEPTION 'negative provider billed cost prohibited'; END IF;

      v_doc:=jsonb_build_object(
        'provider','BRIGHT_DATA',
        'endpoint','/costs/export/json',
        'dimension',p_dimension,
        'cost_day',v_day_date,
        'resource_id',v_resource.key,
        'billed_cost_usd',v_cost,
        'provider_payload_sha256',retail.r1f_sha256_jsonb(p_raw_payload)
      );

      INSERT INTO retail.r1f_provider_daily_resource_costs(
        evidence_id,cost_day,dimension,resource_id,billed_cost_usd,
        resource_document,resource_sha256
      ) VALUES(
        v_evidence_id,v_day_date,p_dimension,v_resource.key,v_cost,
        v_doc,retail.r1f_sha256_jsonb(v_doc)
      )
      ON CONFLICT(evidence_id,cost_day,resource_id) DO NOTHING;

      SELECT id INTO v_resource_id
      FROM retail.r1f_provider_daily_resource_costs
      WHERE evidence_id=v_evidence_id AND cost_day=v_day_date AND resource_id=v_resource.key;

      v_scope:='BRIGHT_DATA:COST_BREAKDOWN:'||p_dimension||':'||v_resource.key;
      PERFORM pg_advisory_xact_lock(hashtextextended(v_scope,0));

      SELECT id,billed_cost_usd INTO v_existing,v_existing_cost
      FROM retail.r1f_provider_cost_authority_periods
      WHERE active=true
        AND provider_scope_key=v_scope
        AND provider_period_start=(v_day_date::timestamp AT TIME ZONE 'UTC')
        AND provider_period_end_exclusive=((v_day_date+1)::timestamp AT TIME ZONE 'UTC')
      LIMIT 1;

      IF v_existing IS NOT NULL AND round(v_existing_cost,8)<>round(v_cost,8) THEN
        RAISE EXCEPTION 'provider cost drift for % on %: existing=% new=%',
          v_resource.key,v_day_date,v_existing_cost,v_cost;
      END IF;

      IF v_existing IS NULL THEN
        v_authority_doc:=jsonb_build_object(
          'authority_source_type','COST_BREAKDOWN',
          'cost_breakdown_evidence_id',v_evidence_id,
          'daily_resource_cost_id',v_resource_id,
          'provider','BRIGHT_DATA',
          'provider_dimension',p_dimension,
          'provider_resource_id',v_resource.key,
          'service_type',v_service_type,
          'provider_period_start',(v_day_date::timestamp AT TIME ZONE 'UTC'),
          'provider_period_end_exclusive',((v_day_date+1)::timestamp AT TIME ZONE 'UTC'),
          'provider_period_type','CALENDAR_DAY',
          'provider_scope_key',v_scope,
          'billed_cost_usd',v_cost,
          'documentation_authority','Bright Data Cost breakdown export'
        );

        INSERT INTO retail.r1f_provider_cost_authority_periods(
          authority_source_type,evidence_id,bucket_id,
          cost_breakdown_evidence_id,daily_resource_cost_id,
          provider,service_type,zone_name,provider_dimension,provider_resource_id,
          provider_period_start,provider_period_end_exclusive,provider_period_type,
          provider_scope_key,billed_cost_usd,bandwidth_bytes,bucket_key,
          semantics_evidence,semantics_sha256,authority_document,authority_sha256,promoted_by
        ) VALUES(
          'COST_BREAKDOWN',NULL,NULL,
          v_evidence_id,v_resource_id,
          'BRIGHT_DATA',v_service_type,NULL,p_dimension,v_resource.key,
          (v_day_date::timestamp AT TIME ZONE 'UTC'),
          ((v_day_date+1)::timestamp AT TIME ZONE 'UTC'),'CALENDAR_DAY',
          v_scope,v_cost,NULL,NULL,
          jsonb_build_object(
            'endpoint','/costs/export/json',
            'dimension',p_dimension,
            'semantics','per-day per-resource billed USD; UTC day; to exclusive'
          ),
          retail.r1f_sha256_jsonb(jsonb_build_object(
            'endpoint','/costs/export/json',
            'dimension',p_dimension,
            'semantics','per-day per-resource billed USD; UTC day; to exclusive'
          )),
          v_authority_doc,retail.r1f_sha256_jsonb(v_authority_doc),p_actor
        );
      END IF;
      v_existing:=NULL;
    END LOOP;
  END LOOP;

  IF p_raw_payload ? 'total' THEN
    FOR v_resource IN
      WITH daily_resources AS (
        SELECT DISTINCT resource.key resource_id
        FROM jsonb_each(p_raw_payload-'total') day
        CROSS JOIN LATERAL jsonb_each(day.value) resource
      ), total_resources AS (
        SELECT key resource_id FROM jsonb_each(p_raw_payload->'total')
      )
      SELECT resource_id
      FROM (
        SELECT resource_id FROM daily_resources
        UNION
        SELECT resource_id FROM total_resources
      ) resources
      ORDER BY resource_id
    LOOP
      SELECT coalesce(sum((day.value->>v_resource.resource_id)::numeric),0)::numeric(18,8)
      INTO v_daily_total
      FROM jsonb_each(p_raw_payload-'total') day
      WHERE day.value ? v_resource.resource_id;

      v_declared_total:=coalesce(
        (p_raw_payload->'total'->>v_resource.resource_id)::numeric,
        0
      )::numeric(18,8);
      IF round(v_daily_total,8)<>round(v_declared_total,8) THEN
        RAISE EXCEPTION
          'cost-breakdown total mismatch for %: daily=% declared=%',
          v_resource.resource_id,v_daily_total,v_declared_total;
      END IF;
    END LOOP;
  END IF;

  RETURN v_evidence_id;
END $$;

-- ---------- PERIOD PROMOTION / OVERLAP PROTECTION ---------------------------

CREATE OR REPLACE FUNCTION retail.r1f_promote_brightdata_bucket_to_authority_period(
  p_evidence_id uuid,
  p_bucket_key text,
  p_period_start timestamptz,
  p_period_end_exclusive timestamptz,
  p_period_type text,
  p_semantics_evidence jsonb,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_e retail.r1f_provider_cost_evidence%ROWTYPE;
  v_b retail.r1f_provider_cost_buckets%ROWTYPE;
  v_scope text;
  v_doc jsonb;
  v_id uuid;
  v_payload_root_key text;
  v_payload_root_count integer;
BEGIN
  IF session_user NOT IN ('retail_r1f_financial_reconciler') AND NOT pg_has_role(session_user,'retail_r1f_financial_reconciler','member') THEN
    RAISE EXCEPTION 'R1F financial reconciler authority required';
  END IF;
  IF p_period_type NOT IN('CALENDAR_DAY','CALENDAR_MONTH','EXACT_REQUEST_RANGE') THEN
    RAISE EXCEPTION 'unsupported provider period type';
  END IF;
  IF p_period_end_exclusive<=p_period_start THEN RAISE EXCEPTION 'invalid provider period'; END IF;
  IF jsonb_typeof(p_semantics_evidence)<>'object' OR p_semantics_evidence='{}'::jsonb THEN
    RAISE EXCEPTION 'non-empty semantic evidence is required for opaque Bright Data bucket';
  END IF;

  SELECT * INTO v_e FROM retail.r1f_provider_cost_evidence
  WHERE id=p_evidence_id AND evidence_version='V2.2'
    AND transport_verified=true AND request_fingerprint_verified=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'V2.2 provider evidence required'; END IF;

  SELECT * INTO v_b FROM retail.r1f_provider_cost_buckets
  WHERE evidence_id=p_evidence_id AND bucket_key=p_bucket_key AND projection_verified=true
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'verified provider bucket required'; END IF;

  IF jsonb_typeof(v_e.raw_payload->'ID')='object' THEN
    v_payload_root_key:='ID';
  ELSE
    SELECT count(*)::int,min(key)
    INTO v_payload_root_count,v_payload_root_key
    FROM jsonb_each(v_e.raw_payload)
    WHERE jsonb_typeof(value)='object';
    IF v_payload_root_count<>1 THEN
      RAISE EXCEPTION 'provider payload no longer has an unambiguous account root';
    END IF;
  END IF;

  -- Hard raw->normalized check inside the DB.
  IF (v_e.raw_payload #>> ARRAY[v_payload_root_key,p_bucket_key,'bw'])::bigint IS DISTINCT FROM v_b.bandwidth_bytes
     OR (v_e.raw_payload #>> ARRAY[v_payload_root_key,p_bucket_key,'cost'])::numeric IS DISTINCT FROM v_b.billed_cost_usd THEN
    RAISE EXCEPTION 'provider bucket projection does not match immutable raw payload';
  END IF;

  v_scope:='BRIGHT_DATA:'||v_e.zone_name||':'||v_e.service_type;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_scope,0));

  IF EXISTS(
    SELECT 1 FROM retail.r1f_provider_cost_authority_periods p
    WHERE p.active=true
      AND p.provider='BRIGHT_DATA'
      AND p.zone_name=v_e.zone_name
      AND p.service_type=v_e.service_type
      AND tstzrange(p.provider_period_start,p.provider_period_end_exclusive,'[)')
          && tstzrange(p_period_start,p_period_end_exclusive,'[)')
  ) THEN
    RAISE EXCEPTION 'overlapping provider financial authority period prohibited for %',v_scope;
  END IF;

  v_doc:=jsonb_build_object(
    'provider','BRIGHT_DATA',
    'evidence_id',v_e.id,
    'bucket_id',v_b.id,
    'bucket_key',v_b.bucket_key,
    'zone_name',v_e.zone_name,
    'service_type',v_e.service_type,
    'provider_period_start',p_period_start,
    'provider_period_end_exclusive',p_period_end_exclusive,
    'provider_period_type',p_period_type,
    'provider_scope_key',v_scope,
    'billed_cost_usd',v_b.billed_cost_usd,
    'bandwidth_bytes',v_b.bandwidth_bytes,
    'raw_payload_sha256',v_e.raw_payload_sha256,
    'semantics_sha256',retail.r1f_sha256_jsonb(p_semantics_evidence)
  );

  INSERT INTO retail.r1f_provider_cost_authority_periods(
    authority_source_type,evidence_id,bucket_id,
    cost_breakdown_evidence_id,daily_resource_cost_id,
    provider,service_type,zone_name,provider_dimension,provider_resource_id,
    provider_period_start,provider_period_end_exclusive,provider_period_type,
    provider_scope_key,billed_cost_usd,bandwidth_bytes,bucket_key,
    semantics_evidence,semantics_sha256,authority_document,authority_sha256,promoted_by
  ) VALUES(
    'ZONE_COST',v_e.id,v_b.id,NULL,NULL,
    'BRIGHT_DATA',v_e.service_type,v_e.zone_name,NULL,NULL,
    p_period_start,p_period_end_exclusive,p_period_type,
    v_scope,v_b.billed_cost_usd,v_b.bandwidth_bytes,v_b.bucket_key,
    p_semantics_evidence,retail.r1f_sha256_jsonb(p_semantics_evidence),
    v_doc,retail.r1f_sha256_jsonb(v_doc),p_actor
  ) RETURNING id INTO v_id;

  RETURN v_id;
END $$;

-- ---------- CAUSAL BINDING ---------------------------------------------------

CREATE OR REPLACE FUNCTION retail.r1f_bind_job_to_provider_cost_period_v22(
  p_authority_period_id uuid,
  p_r1d_job_id uuid,
  p_attribution_basis text,
  p_explicit_weight numeric,
  p_actor text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_p retail.r1f_provider_cost_authority_periods%ROWTYPE;
  v_r retail.r1f_job_provider_execution_receipts%ROWTYPE;
  v_reg retail.r1f_scraper_financial_registry%ROWTYPE;
  v_weight numeric(30,8);
  v_confidence text;
  v_doc jsonb;
  v_id uuid;
BEGIN
  IF session_user NOT IN ('retail_r1f_financial_reconciler') AND NOT pg_has_role(session_user,'retail_r1f_financial_reconciler','member') THEN
    RAISE EXCEPTION 'R1F financial reconciler authority required';
  END IF;

  SELECT * INTO v_p FROM retail.r1f_provider_cost_authority_periods
  WHERE id=p_authority_period_id AND active=true
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'active provider authority period required'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_p.provider_scope_key||':'||v_p.id::text,0));

  IF EXISTS(
    SELECT 1 FROM retail.r1f_provider_job_cost_allocations_v22 a
    WHERE a.authority_period_id=v_p.id
  ) THEN
    RAISE EXCEPTION 'authority period already reconciled and sealed';
  END IF;

  SELECT * INTO v_r FROM retail.r1f_job_provider_execution_receipts
  WHERE r1d_job_id=p_r1d_job_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'immutable provider execution receipt required'; END IF;

  SELECT * INTO v_reg FROM retail.r1f_scraper_financial_registry
  WHERE id=v_r.scraper_registry_id AND active=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'active scraper registry required'; END IF;

  IF v_p.authority_source_type='ZONE_COST' THEN
    IF v_r.billing_authority<>'ZONE_COST' THEN
      RAISE EXCEPTION 'job billing authority % cannot bind to /zone/cost period',v_r.billing_authority;
    END IF;
    IF v_r.zone_name IS DISTINCT FROM v_p.zone_name
       OR v_r.service_type IS DISTINCT FROM v_p.service_type THEN
      RAISE EXCEPTION 'job provider zone/service does not match provider authority period';
    END IF;
  ELSIF v_p.authority_source_type='COST_BREAKDOWN' THEN
    IF v_r.billing_authority<>'COST_BREAKDOWN' THEN
      RAISE EXCEPTION 'job billing authority % cannot bind to cost-breakdown period',v_r.billing_authority;
    END IF;
    IF v_r.service_type IS DISTINCT FROM v_p.service_type THEN
      RAISE EXCEPTION 'job service type does not match cost-breakdown authority';
    END IF;
    IF v_p.provider_dimension='web_apis'
       AND v_r.dataset_id IS DISTINCT FROM v_p.provider_resource_id THEN
      RAISE EXCEPTION 'job dataset_id does not match Bright Data web_apis resource';
    ELSIF v_p.provider_dimension='collectors'
       AND v_r.collector_id IS DISTINCT FROM v_p.provider_resource_id THEN
      RAISE EXCEPTION 'job collector_id does not match Bright Data collector resource';
    ELSIF v_p.provider_dimension='ws_api_snaps'
       AND v_r.snapshot_id IS DISTINCT FROM v_p.provider_resource_id THEN
      RAISE EXCEPTION 'job snapshot_id does not match Bright Data WSA snapshot resource';
    ELSIF v_p.provider_dimension NOT IN('web_apis','collectors','ws_api_snaps') THEN
      RAISE EXCEPTION 'unsupported cost-breakdown dimension %',v_p.provider_dimension;
    END IF;
  ELSE
    RAISE EXCEPTION 'unsupported authority source type %',v_p.authority_source_type;
  END IF;
  IF v_p.provider_dimension='ws_api_snaps'
     AND p_attribution_basis<>'DIRECT_RESOURCE' THEN
    RAISE EXCEPTION 'ws_api_snaps requires DIRECT_RESOURCE attribution';
  ELSIF v_p.provider_dimension IS DISTINCT FROM 'ws_api_snaps'
        AND p_attribution_basis='DIRECT_RESOURCE' THEN
    RAISE EXCEPTION 'DIRECT_RESOURCE attribution is reserved for ws_api_snaps';
  END IF;
  IF NOT (
    v_r.started_at_utc < v_p.provider_period_end_exclusive
    AND v_r.completed_at_utc >= v_p.provider_period_start
  ) THEN
    RAISE EXCEPTION 'job execution does not intersect provider authority period';
  END IF;

  CASE p_attribution_basis
    WHEN 'DIRECT_RESOURCE' THEN
      v_weight:=1;
      v_confidence:='DIRECT_CAUSAL';
    WHEN 'PROVIDER_BYTES' THEN
      IF coalesce(v_r.provider_bandwidth_bytes,0)<=0 THEN RAISE EXCEPTION 'provider bytes required'; END IF;
      v_weight:=v_r.provider_bandwidth_bytes::numeric;
      v_confidence:='DIRECT_CAUSAL';
    WHEN 'PROVIDER_REQUESTS' THEN
      IF coalesce(v_r.provider_request_count,0)<=0 THEN RAISE EXCEPTION 'provider request count required'; END IF;
      v_weight:=v_r.provider_request_count::numeric;
      v_confidence:='HIGH';
    WHEN 'RECORDS_COLLECTED' THEN
      IF coalesce(v_r.records_collected,0)<=0 THEN RAISE EXCEPTION 'records_collected required'; END IF;
      v_weight:=v_r.records_collected::numeric;
      v_confidence:='ALLOCATED_NON_CAUSAL';
    WHEN 'RECORDS_REQUESTED' THEN
      IF coalesce(v_r.records_requested,0)<=0 THEN RAISE EXCEPTION 'records_requested required'; END IF;
      v_weight:=v_r.records_requested::numeric;
      v_confidence:='ALLOCATED_NON_CAUSAL';
    WHEN 'EQUAL_SHARE' THEN
      v_weight:=1;
      v_confidence:='ALLOCATED_NON_CAUSAL';
    WHEN 'EXPLICIT_WEIGHT' THEN
      IF coalesce(p_explicit_weight,0)<=0 THEN RAISE EXCEPTION 'positive explicit weight required'; END IF;
      v_weight:=p_explicit_weight;
      v_confidence:='MEDIUM';
    ELSE
      RAISE EXCEPTION 'unsupported attribution basis';
  END CASE;

  IF v_p.provider_dimension IN('web_apis','collectors') THEN
    v_confidence:='ALLOCATED_NON_CAUSAL';
  END IF;

  v_doc:=jsonb_build_object(
    'authority_period_id',v_p.id,
    'r1d_job_id',p_r1d_job_id,
    'execution_receipt_id',v_r.id,
    'scraper_registry_id',v_reg.id,
    'zone_name',v_r.zone_name,
    'service_type',v_r.service_type,
    'execution_start',v_r.started_at_utc,
    'execution_end',v_r.completed_at_utc,
    'provider_period_start',v_p.provider_period_start,
    'provider_period_end_exclusive',v_p.provider_period_end_exclusive,
    'attribution_basis',p_attribution_basis,
    'attribution_weight',v_weight,
    'attribution_confidence',v_confidence
  );

  INSERT INTO retail.r1f_provider_job_cost_bindings_v22(
    authority_period_id,r1d_job_id,execution_receipt_id,scraper_registry_id,
    attribution_basis,attribution_weight,attribution_confidence,
    binding_document,binding_sha256,created_by
  ) VALUES(
    v_p.id,p_r1d_job_id,v_r.id,v_reg.id,
    p_attribution_basis,v_weight,v_confidence,
    v_doc,retail.r1f_sha256_jsonb(v_doc),p_actor
  ) RETURNING id INTO v_id;

  RETURN v_id;
END $$;

-- ---------- EXACT NUMERIC RECONCILIATION -----------------------------------

CREATE OR REPLACE FUNCTION retail.r1f_reconcile_provider_cost_period_v22(
  p_authority_period_id uuid,
  p_actor text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_p retail.r1f_provider_cost_authority_periods%ROWTYPE;
  v_count integer;
  v_den numeric(30,8);
  v_sum numeric(18,8);
  v_row record;
  v_alloc numeric(18,8);
  v_running numeric(18,8):=0;
  v_status text;
  v_usage_status text;
  v_doc jsonb;
  v_expected_jobs integer;
  v_uncovered_jobs integer;
BEGIN
  IF session_user NOT IN ('retail_r1f_financial_reconciler') AND NOT pg_has_role(session_user,'retail_r1f_financial_reconciler','member') THEN
    RAISE EXCEPTION 'R1F financial reconciler authority required';
  END IF;

  SELECT * INTO v_p
  FROM retail.r1f_provider_cost_authority_periods
  WHERE id=p_authority_period_id AND active=true
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'active provider authority period required'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_p.provider_scope_key||':'||v_p.id::text,0));

  IF EXISTS(SELECT 1 FROM retail.r1f_provider_job_cost_allocations_v22 WHERE authority_period_id=v_p.id) THEN
    RAISE EXCEPTION 'provider authority period already reconciled';
  END IF;

  SELECT count(*)::int,coalesce(sum(attribution_weight),0)::numeric(30,8)
  INTO v_count,v_den
  FROM retail.r1f_provider_job_cost_bindings_v22
  WHERE authority_period_id=v_p.id;

  IF v_count=0 OR v_den<=0 THEN RAISE EXCEPTION 'bindings required before reconciliation'; END IF;

  IF v_p.provider_dimension='web_apis' THEN
    WITH eligible AS (
      SELECT DISTINCT job.id
      FROM retail.r1d_dispatch_jobs job
      JOIN retail.r1d_dispatch_attempts attempt
        ON attempt.job_id=job.id AND attempt.success=true
      JOIN retail.collection_runs run
        ON attempt.metrics_json->>'collection_run_id' ~
           '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
       AND run.id=(attempt.metrics_json->>'collection_run_id')::uuid
      WHERE job.status='succeeded'
        AND run.run_metadata->>'dataset_id'=v_p.provider_resource_id
        AND run.started_at<v_p.provider_period_end_exclusive
        AND coalesce(run.completed_at,run.started_at)>=v_p.provider_period_start
    )
    SELECT count(*)::int,
           count(*) FILTER(where binding.id IS NULL)::int
    INTO v_expected_jobs,v_uncovered_jobs
    FROM eligible
    LEFT JOIN retail.r1f_provider_job_cost_bindings_v22 binding
      ON binding.authority_period_id=v_p.id
     AND binding.r1d_job_id=eligible.id;

    IF v_expected_jobs=0 OR v_expected_jobs<>v_count OR v_uncovered_jobs<>0
       OR EXISTS(
         SELECT 1
         FROM retail.r1f_provider_job_cost_bindings_v22 binding
         WHERE binding.authority_period_id=v_p.id
           AND NOT EXISTS(
             SELECT 1
             FROM retail.r1d_dispatch_attempts attempt
             JOIN retail.collection_runs run
               ON attempt.metrics_json->>'collection_run_id' ~
                  '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
              AND run.id=(attempt.metrics_json->>'collection_run_id')::uuid
             WHERE attempt.job_id=binding.r1d_job_id
               AND attempt.success=true
               AND run.run_metadata->>'dataset_id'=v_p.provider_resource_id
               AND run.started_at<v_p.provider_period_end_exclusive
               AND coalesce(run.completed_at,run.started_at)>=v_p.provider_period_start
           )
       ) THEN
      RAISE EXCEPTION
        'dataset/day allocation requires complete R1D execution coverage: eligible=% bound=% uncovered=%',
        v_expected_jobs,v_count,v_uncovered_jobs;
    END IF;
  ELSIF v_p.provider_dimension='ws_api_snaps' THEN
    IF v_count<>1 OR v_den<>1 OR EXISTS(
      SELECT 1
      FROM retail.r1f_provider_job_cost_bindings_v22 binding
      WHERE binding.authority_period_id=v_p.id
        AND (binding.attribution_basis<>'DIRECT_RESOURCE'
             OR binding.attribution_confidence<>'DIRECT_CAUSAL')
    ) THEN
      RAISE EXCEPTION 'ws_api_snaps requires exactly one directly attributed R1D job';
    END IF;
  END IF;

  v_status:=CASE WHEN v_p.billed_cost_usd>0
                 THEN 'PROVIDER_PAID_COST_RECONCILED'
                 ELSE 'PROVIDER_ZERO_COST_CONFIRMED' END;
  v_usage_status:=CASE
    WHEN v_p.authority_source_type='COST_BREAKDOWN' AND v_p.billed_cost_usd>0
      THEN 'PROVIDER_USAGE_CONFIRMED'
    WHEN v_p.authority_source_type='COST_BREAKDOWN'
      THEN 'PROVIDER_USAGE_ZERO'
    WHEN coalesce(v_p.bandwidth_bytes,0)>0
      THEN 'PROVIDER_USAGE_CONFIRMED'
    ELSE 'PROVIDER_USAGE_ZERO'
  END;

  FOR v_row IN
    SELECT b.*,
           row_number() over(order by b.r1d_job_id,b.id) rn,
           count(*) over() cnt
    FROM retail.r1f_provider_job_cost_bindings_v22 b
    WHERE b.authority_period_id=v_p.id
    ORDER BY b.r1d_job_id,b.id
  LOOP
    IF v_row.rn=v_row.cnt THEN
      v_alloc:=round(v_p.billed_cost_usd-v_running,8);
    ELSE
      v_alloc:=round(v_p.billed_cost_usd*v_row.attribution_weight/v_den,8);
      v_running:=round(v_running+v_alloc,8);
    END IF;
    IF v_alloc<0 THEN RAISE EXCEPTION 'negative residual allocation'; END IF;

    v_doc:=jsonb_build_object(
      'authority_period_id',v_p.id,
      'binding_id',v_row.id,
      'r1d_job_id',v_row.r1d_job_id,
      'execution_receipt_id',v_row.execution_receipt_id,
      'scraper_registry_id',v_row.scraper_registry_id,
      'provider_billed_cost_usd',v_p.billed_cost_usd,
      'provider_bandwidth_bytes',v_p.bandwidth_bytes,
      'allocation_numerator',v_row.attribution_weight,
      'allocation_denominator',v_den,
      'allocated_provider_cost_usd',v_alloc,
      'attribution_method',v_row.attribution_basis,
      'attribution_confidence',v_row.attribution_confidence,
      'usage_verification_status',v_usage_status,
      'financial_verification_status',v_status,
      'authority_sha256',v_p.authority_sha256
    );

    INSERT INTO retail.r1f_provider_job_cost_allocations_v22(
      authority_period_id,binding_id,r1d_job_id,execution_receipt_id,scraper_registry_id,
      provider_billed_cost_usd,provider_bandwidth_bytes,
      allocation_numerator,allocation_denominator,allocated_provider_cost_usd,
      attribution_method,attribution_confidence,
      usage_verification_status,financial_verification_status,
      allocation_document,allocation_sha256,reconciled_by
    ) VALUES(
      v_p.id,v_row.id,v_row.r1d_job_id,v_row.execution_receipt_id,v_row.scraper_registry_id,
      v_p.billed_cost_usd,v_p.bandwidth_bytes,
      v_row.attribution_weight,v_den,v_alloc,
      v_row.attribution_basis,v_row.attribution_confidence,
      v_usage_status,v_status,
      v_doc,retail.r1f_sha256_jsonb(v_doc),p_actor
    );
  END LOOP;

  SELECT coalesce(sum(allocated_provider_cost_usd),0)::numeric(18,8)
  INTO v_sum
  FROM retail.r1f_provider_job_cost_allocations_v22
  WHERE authority_period_id=v_p.id;

  IF round(v_sum,8)<>round(v_p.billed_cost_usd,8) THEN
    RAISE EXCEPTION 'provider cost conservation failed allocated=% billed=%',v_sum,v_p.billed_cost_usd;
  END IF;

  RETURN jsonb_build_object(
    'authority_period_id',v_p.id,
    'job_count',v_count,
    'provider_billed_cost_usd',v_p.billed_cost_usd,
    'allocated_provider_cost_usd',v_sum,
    'financial_verification_status',v_status,
    'usage_verification_status',v_usage_status
  );
END $$;

-- ---------- EFFECTIVE V2.2 AUTHORITY ----------------------------------------

CREATE OR REPLACE VIEW retail.r1f_effective_provider_job_cost AS
SELECT
  a.r1d_job_id,
  a.id reconciliation_id,
  p.evidence_id,
  p.bucket_id,
  p.provider,
  p.service_type,
  p.zone_name,
  p.provider_period_start::date period_from,
  p.provider_period_end_exclusive::date period_to_exclusive,
  p.bucket_key,
  p.bandwidth_bytes provider_bandwidth_bytes,
  p.billed_cost_usd provider_billed_cost_usd,
  a.allocated_provider_cost_usd allocated_cost_usd,
  a.attribution_method,
  a.financial_verification_status reconciliation_status,
  a.allocation_sha256 reconciliation_sha256,
  a.reconciled_at
FROM retail.r1f_provider_job_cost_allocations_v22 a
JOIN retail.r1f_provider_cost_authority_periods p ON p.id=a.authority_period_id
WHERE p.active=true;

-- ---------- FACT SEMANTICS: ALLOCATED PROVIDER COST, NOT DIRECT PROVIDER JOB COST

ALTER TABLE retail.r1f_job_facts
  ADD COLUMN IF NOT EXISTS allocated_provider_cost_usd numeric(18,8),
  ADD COLUMN IF NOT EXISTS provider_usage_verification_status text,
  ADD COLUMN IF NOT EXISTS provider_financial_verification_status text,
  ADD COLUMN IF NOT EXISTS provider_execution_receipt_id uuid
    REFERENCES retail.r1f_job_provider_execution_receipts(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS provider_scraper_registry_id uuid
    REFERENCES retail.r1f_scraper_financial_registry(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS provider_cost_breakdown_evidence_id uuid
    REFERENCES retail.r1f_provider_cost_breakdown_evidence(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS provider_dimension text,
  ADD COLUMN IF NOT EXISTS provider_resource_id text;

ALTER TABLE retail.r1f_job_facts
  DROP CONSTRAINT IF EXISTS r1f_job_facts_cost_basis_check;

ALTER TABLE retail.r1f_job_facts
  ADD CONSTRAINT r1f_job_facts_cost_basis_check CHECK(cost_basis IN(
    'actual','allocated_provider','estimated'
  ));

ALTER TABLE retail.r1f_job_facts
  DROP CONSTRAINT IF EXISTS r1f_job_cost_authority_check;

ALTER TABLE retail.r1f_job_facts
  ADD CONSTRAINT r1f_job_cost_authority_check CHECK(cost_authority IN(
    'R1D_DIRECT','BRIGHT_DATA_ZONE_COST','BRIGHT_DATA_COST_BREAKDOWN',
    'BRIGHT_DATA_SNAPSHOT_DIRECT','ESTIMATE'
  ));

-- Retain legacy actual_cost_usd for compatibility; V2.2 documents it as effective allocated provider cost.
CREATE OR REPLACE FUNCTION retail.r1f_financial_fact_integration()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  r record;
BEGIN
  IF TG_OP='INSERT' THEN
    SELECT a.*,p.evidence_id,p.cost_breakdown_evidence_id,
           p.authority_source_type,p.zone_name,p.provider_dimension,p.provider_resource_id,
           p.billed_cost_usd,p.bandwidth_bytes
    INTO r
    FROM retail.r1f_provider_job_cost_allocations_v22 a
    JOIN retail.r1f_provider_cost_authority_periods p ON p.id=a.authority_period_id
    WHERE a.r1d_job_id=NEW.r1d_job_id;

    IF FOUND THEN
      NEW.actual_cost_usd:=r.allocated_provider_cost_usd;
      NEW.allocated_provider_cost_usd:=r.allocated_provider_cost_usd;
      NEW.cost_basis:=CASE
        WHEN r.provider_dimension='ws_api_snaps' THEN 'actual'
        ELSE 'allocated_provider'
      END;
      NEW.actual_cost_coverage:=1;
      NEW.cost_authority:=CASE
        WHEN r.provider_dimension='ws_api_snaps' THEN 'BRIGHT_DATA_SNAPSHOT_DIRECT'
        WHEN r.authority_source_type='COST_BREAKDOWN' THEN 'BRIGHT_DATA_COST_BREAKDOWN'
        ELSE 'BRIGHT_DATA_ZONE_COST'
      END;
      NEW.provider_cost_evidence_id:=r.evidence_id;
      NEW.provider_cost_breakdown_evidence_id:=r.cost_breakdown_evidence_id;
      NEW.provider_dimension:=r.provider_dimension;
      NEW.provider_resource_id:=r.provider_resource_id;
      NEW.provider_cost_reconciliation_id:=NULL; -- V2.2 authority is allocation table, not V2.1 reconciliation.
      NEW.provider_zone_name:=r.zone_name;
      NEW.cost_attribution_method:=r.attribution_method;
      NEW.provider_billed_cost_usd:=r.billed_cost_usd;
      NEW.provider_bandwidth_bytes:=r.bandwidth_bytes;
      NEW.provider_cost_reconciled_at:=r.reconciled_at;
      NEW.provider_usage_verification_status:=r.usage_verification_status;
      NEW.provider_financial_verification_status:=r.financial_verification_status;
      NEW.provider_execution_receipt_id:=r.execution_receipt_id;
      NEW.provider_scraper_registry_id:=r.scraper_registry_id;
    ELSIF NEW.cost_basis='actual' THEN
      NEW.cost_authority:='R1D_DIRECT';
    ELSE
      NEW.cost_authority:='ESTIMATE';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP='UPDATE'
     AND current_setting('r1f.fact_finalize',true)='true' THEN
    NEW.fact_document:=NEW.fact_document || jsonb_build_object(
      'search_cost_usd',NEW.actual_cost_usd,
      'allocated_provider_cost_usd',NEW.allocated_provider_cost_usd,
      'cost_basis',NEW.cost_basis,
      'financial_cost',jsonb_build_object(
        'authority',NEW.cost_authority,
        'provider_cost_evidence_id',NEW.provider_cost_evidence_id,
        'provider_cost_breakdown_evidence_id',NEW.provider_cost_breakdown_evidence_id,
        'provider_dimension',NEW.provider_dimension,
        'provider_resource_id',NEW.provider_resource_id,
        'provider_zone_name',NEW.provider_zone_name,
        'attribution_method',NEW.cost_attribution_method,
        'provider_billed_cost_usd',NEW.provider_billed_cost_usd,
        'provider_bandwidth_bytes',NEW.provider_bandwidth_bytes,
        'provider_cost_reconciled_at',NEW.provider_cost_reconciled_at,
        'usage_verification_status',NEW.provider_usage_verification_status,
        'financial_verification_status',NEW.provider_financial_verification_status,
        'execution_receipt_id',NEW.provider_execution_receipt_id,
        'scraper_registry_id',NEW.provider_scraper_registry_id
      )
    );
    NEW.fact_sha256:=retail.r1f_sha256_jsonb(NEW.fact_document);
    RETURN NEW;
  END IF;

  RETURN NEW;
END $$;

-- ---------- GLOBAL INTEGRITY + CURRENT-SCOPE STATUS --------------------------

CREATE OR REPLACE VIEW retail.r1f_financial_v22_global_integrity AS
WITH active_att AS (
  SELECT *
  FROM retail.r1f_scraper_repository_attestations
  ORDER BY attested_at DESC,id DESC
  LIMIT 1
), reg AS (
  SELECT
    count(*)::int active_scrapers,
    count(*) FILTER(where financial_identity_sha256=retail.r1f_sha256_jsonb(financial_identity_document))::int registry_hash_valid
  FROM retail.r1f_scraper_financial_registry r,active_att a
  WHERE r.repository_attestation_id=a.id AND r.active=true
), rec AS (
  SELECT
    count(*)::int receipts,
    count(*) FILTER(where x.receipt_sha256=retail.r1f_sha256_jsonb(x.receipt_document))::int receipt_hash_valid,
    count(distinct x.scraper_registry_id)::int scrapers_with_receipts
  FROM retail.r1f_job_provider_execution_receipts x
  JOIN retail.r1f_scraper_financial_registry r ON r.id=x.scraper_registry_id
  JOIN active_att a ON a.id=r.repository_attestation_id
), alloc AS (
  SELECT
    count(*)::int allocations,
    count(distinct x.scraper_registry_id)::int scrapers_with_allocations,
    count(*) FILTER(where x.allocation_sha256=retail.r1f_sha256_jsonb(x.allocation_document))::int allocation_hash_valid,
    count(*) FILTER(where x.financial_verification_status='PROVIDER_PAID_COST_RECONCILED')::int paid_allocations,
    count(*) FILTER(where x.financial_verification_status='PROVIDER_ZERO_COST_CONFIRMED')::int zero_cost_allocations
  FROM retail.r1f_provider_job_cost_allocations_v22 x
  JOIN retail.r1f_scraper_financial_registry r ON r.id=x.scraper_registry_id
  JOIN active_att a ON a.id=r.repository_attestation_id
), period_balance AS (
  SELECT
    p.id,
    p.billed_cost_usd,
    coalesce(sum(a.allocated_provider_cost_usd),0)::numeric(18,8) allocated
  FROM retail.r1f_provider_cost_authority_periods p
  LEFT JOIN retail.r1f_provider_job_cost_allocations_v22 a ON a.authority_period_id=p.id
  WHERE p.active=true
  GROUP BY p.id,p.billed_cost_usd
)
SELECT
  a.commit_sha,
  a.expected_scraper_count,
  a.discovered_scraper_count,
  reg.active_scrapers,
  reg.registry_hash_valid,
  rec.receipts,
  rec.receipt_hash_valid,
  rec.scrapers_with_receipts,
  alloc.allocations,
  alloc.scrapers_with_allocations,
  alloc.allocation_hash_valid,
  alloc.paid_allocations,
  alloc.zero_cost_allocations,
  (SELECT count(*)::int FROM period_balance) provider_periods,
  (SELECT count(*)::int FROM period_balance WHERE round(billed_cost_usd,8)=round(allocated,8)) balanced_provider_periods,
  (SELECT count(*)::int FROM retail.r1f_provider_job_cost_bindings_v22 b
     LEFT JOIN retail.r1f_provider_job_cost_allocations_v22 x ON x.binding_id=b.id
     WHERE x.id IS NULL) orphan_unreconciled_bindings,
  (SELECT count(*)::int FROM retail.r1f_provider_cost_authority_periods p
     WHERE p.active=true
       AND NOT EXISTS(SELECT 1 FROM retail.r1f_provider_job_cost_allocations_v22 x WHERE x.authority_period_id=p.id)) unreconciled_authority_periods
FROM active_att a CROSS JOIN reg CROSS JOIN rec CROSS JOIN alloc;

-- ---------- HARDENED CERTIFICATION POLICY ----------------------------------

CREATE OR REPLACE FUNCTION retail.r1f_validate_certification_policy(
  p_policy jsonb
)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_class text;
  v_required jsonb:='{
    "high_opportunity":75,
    "low_opportunity":75,
    "insufficient_sample":75,
    "high_cost":75,
    "strong_bargain":75,
    "weak_availability":75,
    "exploration":50,
    "nationwide_ranking":50,
    "strategy_convergence":50
  }'::jsonb;
BEGIN
  IF p_policy IS NULL OR jsonb_typeof(p_policy)<>'object' THEN
    RAISE EXCEPTION 'R1F certification policy must be object';
  END IF;

  IF COALESCE((p_policy->>'minimum_total_fixtures')::int,0)<625
     OR COALESCE((p_policy->>'minimum_e2e_scenarios')::int,0)<10
     OR COALESCE((p_policy->>'minimum_e2e_jobs')::int,0)<50
     OR COALESCE((p_policy->>'minimum_e2e_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_score_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_recommendation_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_ranking_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_convergence_accuracy')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_replay_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_fact_hash_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_snapshot_hash_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_recommendation_hash_coverage')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_actual_cost_coverage_pct')::numeric,-1)<80
     OR COALESCE((p_policy->>'minimum_provider_reconciled_cost_coverage_pct')::numeric,-1)<80
     OR COALESCE((p_policy->>'minimum_provider_reconciliation_balance_pct')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_local_timezone_coverage_pct')::numeric,-1)<95
     OR COALESCE((p_policy->>'minimum_scraper_registry_coverage_pct')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_scraper_execution_receipt_coverage_pct')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_financial_hash_integrity_pct')::numeric,-1)<100
     OR COALESCE((p_policy->>'minimum_provider_paid_cost_sample_jobs')::int,0)<1 THEN
    RAISE EXCEPTION 'R1F V2.2 certification policy weaker than Green Tier 1';
  END IF;

  IF jsonb_typeof(COALESCE(p_policy->'class_minimums','{}'::jsonb))<>'object' THEN
    RAISE EXCEPTION 'R1F V2.2 class_minimums must be object';
  END IF;

  FOR v_class IN SELECT jsonb_object_keys(v_required)
  LOOP
    IF COALESCE((p_policy#>>ARRAY['class_minimums',v_class])::int,0)
       < (v_required->>v_class)::int THEN
      RAISE EXCEPTION 'R1F V2.2 class % minimum below Green Tier floor %',
        v_class,(v_required->>v_class)::int;
    END IF;
  END LOOP;
END $$;

-- ---------- PRIVILEGES -------------------------------------------------------

REVOKE ALL ON retail.r1f_scraper_repository_attestations FROM PUBLIC;
REVOKE ALL ON retail.r1f_scraper_financial_registry FROM PUBLIC;
REVOKE ALL ON retail.r1f_provider_zone_registry FROM PUBLIC;
REVOKE ALL ON retail.r1f_job_provider_execution_receipts FROM PUBLIC;
REVOKE ALL ON retail.r1f_provider_cost_breakdown_evidence FROM PUBLIC;
REVOKE ALL ON retail.r1f_provider_daily_resource_costs FROM PUBLIC;
REVOKE ALL ON retail.r1f_provider_cost_authority_periods FROM PUBLIC;
REVOKE ALL ON retail.r1f_provider_job_cost_bindings_v22 FROM PUBLIC;
REVOKE ALL ON retail.r1f_provider_job_cost_allocations_v22 FROM PUBLIC;

GRANT SELECT ON retail.r1f_scraper_repository_attestations,retail.r1f_scraper_financial_registry,
  retail.r1f_provider_zone_registry,retail.r1f_job_provider_execution_receipts,
  retail.r1f_provider_cost_breakdown_evidence,retail.r1f_provider_daily_resource_costs,
  retail.r1f_provider_cost_authority_periods,retail.r1f_provider_job_cost_bindings_v22,
  retail.r1f_provider_job_cost_allocations_v22,retail.r1f_financial_v22_global_integrity
TO retail_r1f_reader,retail_r1f_certifier;

-- SECURITY DEFINER functions have PUBLIC EXECUTE by default in PostgreSQL.
-- Fail closed: revoke PUBLIC/generic worker execution before granting narrowly scoped roles.
REVOKE EXECUTE ON FUNCTION retail.r1f_register_scraper_repository_attestation(text,text,text,jsonb,text) FROM PUBLIC,retail_r1f_worker;
REVOKE EXECUTE ON FUNCTION retail.r1f_register_scraper_financial_identity(uuid,text,text,text,uuid,text,text,text,text,text,text,jsonb,text) FROM PUBLIC,retail_r1f_worker;
REVOKE EXECUTE ON FUNCTION retail.r1f_register_provider_zone(text,text,text,text) FROM PUBLIC,retail_r1f_worker;
REVOKE EXECUTE ON FUNCTION retail.r1f_record_job_provider_execution_receipt(uuid,text,text,text,text,text,text,text,text,timestamptz,timestamptz,bigint,bigint,bigint,bigint,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION retail.r1f_record_brightdata_zone_cost_response(text,date,date,integer,jsonb,uuid,text,text) FROM PUBLIC,retail_r1f_worker;
REVOKE EXECUTE ON FUNCTION retail.r1f_record_brightdata_cost_breakdown_response(text,date,date,integer,jsonb,uuid,text,text) FROM PUBLIC,retail_r1f_worker;
REVOKE EXECUTE ON FUNCTION retail.r1f_promote_brightdata_bucket_to_authority_period(uuid,text,timestamptz,timestamptz,text,jsonb,text) FROM PUBLIC,retail_r1f_worker;
REVOKE EXECUTE ON FUNCTION retail.r1f_bind_job_to_provider_cost_period_v22(uuid,uuid,text,numeric,text) FROM PUBLIC,retail_r1f_worker;
REVOKE EXECUTE ON FUNCTION retail.r1f_reconcile_provider_cost_period_v22(uuid,text) FROM PUBLIC,retail_r1f_worker;

GRANT EXECUTE ON FUNCTION retail.r1f_register_scraper_repository_attestation(text,text,text,jsonb,text)
TO retail_r1f_financial_registry;
GRANT EXECUTE ON FUNCTION retail.r1f_register_scraper_financial_identity(uuid,text,text,text,uuid,text,text,text,text,text,text,jsonb,text)
TO retail_r1f_financial_registry;
GRANT EXECUTE ON FUNCTION retail.r1f_register_provider_zone(text,text,text,text)
TO retail_r1f_financial_registry;

GRANT EXECUTE ON FUNCTION retail.r1f_record_job_provider_execution_receipt(uuid,text,text,text,text,text,text,text,text,timestamptz,timestamptz,bigint,bigint,bigint,bigint,text)
TO retail_r1f_worker;

GRANT EXECUTE ON FUNCTION retail.r1f_record_brightdata_zone_cost_response(text,date,date,integer,jsonb,uuid,text,text)
TO retail_r1f_financial_collector;
GRANT EXECUTE ON FUNCTION retail.r1f_record_brightdata_cost_breakdown_response(text,date,date,integer,jsonb,uuid,text,text)
TO retail_r1f_financial_collector;

GRANT EXECUTE ON FUNCTION retail.r1f_promote_brightdata_bucket_to_authority_period(uuid,text,timestamptz,timestamptz,text,jsonb,text)
TO retail_r1f_financial_reconciler;
GRANT EXECUTE ON FUNCTION retail.r1f_bind_job_to_provider_cost_period_v22(uuid,uuid,text,numeric,text)
TO retail_r1f_financial_reconciler;
GRANT EXECUTE ON FUNCTION retail.r1f_reconcile_provider_cost_period_v22(uuid,text)
TO retail_r1f_financial_reconciler;

UPDATE retail.r1f_financial_consumption_state
SET layer_version='2.2.0',
    provider_contract='BRIGHT_DATA_MULTI_PRODUCT_FINANCIAL_AUTHORITY_V2_2'
WHERE singleton=true;

COMMIT;
