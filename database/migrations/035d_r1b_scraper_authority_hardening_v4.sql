BEGIN;

-- ============================================================================
-- TCDS R1B V4 — SCRAPER AUTHORITY HARDENING
-- Applies AFTER:
--   035_r1b_route_authority_v3.sql
--   035c_r1b_existing_scraper_integration_a1.sql
--
-- Closes eight freeze blockers:
-- 1. execution-ready scraper contract wired into route authority
-- 2. scraper asset/contract identity included in adapter/route authority hashes
-- 3. no retrofit of scraper authority onto certified adapter versions
-- 4. file + package-tree runtime attestation
-- 5. governed scraper contract lifecycle + ARB process provenance
-- 6. integration certification cannot pass an empty production universe
-- 7. evidence JSON hashes are recomputed/verified in PostgreSQL
-- 8. db_ingest_targets validated against real retail schema/platform
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('retail.r1b_schema_state') IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM retail.r1b_schema_state
       WHERE singleton=true AND schema_version='3.0.0'
     ) THEN
    RAISE EXCEPTION 'R1B V4 scraper hardening requires R1B core schema 3.0.0';
  END IF;

  IF to_regclass('retail.retail_scraper_assets') IS NULL
     OR to_regclass('retail.retail_scraper_contracts') IS NULL
     OR to_regclass('retail.retail_search_adapters') IS NULL
     OR to_regclass('retail.search_route_bindings') IS NULL THEN
    RAISE EXCEPTION 'R1B V4 scraper hardening requires 035c integration objects';
  END IF;

  IF to_regclass('arb.process_registry') IS NULL
     OR to_regclass('arb.process_runs') IS NULL
     OR to_regclass('retail_audit.retail_change_log') IS NULL THEN
    RAISE EXCEPTION 'R1B V4 governance dependencies missing';
  END IF;
END $$;

-- --------------------------------------------------------------------------
-- VERSION MARKER
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.r1b_scraper_authority_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  hardening_version text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user,
  doctrine text NOT NULL
);

INSERT INTO retail.r1b_scraper_authority_state(
  singleton,hardening_version,doctrine
)
VALUES(
  true,'4.0.0',
  'Existing retailer scrapers are immutable execution assets. A route is executable only when its exact scraper asset and scraper contract are current, certified, cryptographically bound, and runtime-attestable.'
)
ON CONFLICT(singleton) DO UPDATE SET
  hardening_version=EXCLUDED.hardening_version,
  doctrine=EXCLUDED.doctrine;

-- --------------------------------------------------------------------------
-- PROVENANCE REGISTRY
-- --------------------------------------------------------------------------
INSERT INTO arb.process_registry(
  process_name,phase_no,process_group,description,owner_team,active_flag
)
VALUES
('RETAIL_R1B_SCRAPER_INVENTORY',2,'RETAIL_AUTOMATION',
 'Inventory/hash existing retailer scraper assets from the deployed repository.',
 'TCDS Retail Automation',true),
('RETAIL_R1B_SCRAPER_CONTRACT_REGISTER',2,'RETAIL_AUTOMATION',
 'Register an immutable scraper interface contract candidate.',
 'TCDS Retail Automation',true),
('RETAIL_R1B_SCRAPER_CONTRACT_VERIFY',2,'RETAIL_AUTOMATION',
 'Verify exact scraper interface contract against implementation evidence.',
 'TCDS Retail Automation',true),
('RETAIL_R1B_SCRAPER_CONTRACT_QA',2,'RETAIL_AUTOMATION',
 'Record QA passage for an exact scraper contract version.',
 'TCDS Retail Automation',true),
('RETAIL_R1B_SCRAPER_CONTRACT_CERTIFY',2,'RETAIL_AUTOMATION',
 'Certify exact scraper contract for R1 execution.',
 'TCDS Retail Automation',true),
('RETAIL_R1B_SCRAPER_CONTRACT_BLOCK',2,'RETAIL_AUTOMATION',
 'Block a scraper contract from R1 execution.',
 'TCDS Retail Automation',true),
('RETAIL_R1B_SCRAPER_CONTRACT_RETIRE',2,'RETAIL_AUTOMATION',
 'Retire a scraper contract permanently.',
 'TCDS Retail Automation',true),
('RETAIL_R1B_SCRAPER_INTEGRATION_CERTIFY',2,'RETAIL_AUTOMATION',
 'Certify non-empty existing-scraper integration readiness.',
 'TCDS Retail Automation',true)
ON CONFLICT(process_name) DO NOTHING;

-- --------------------------------------------------------------------------
-- ASSET / CONTRACT PROVENANCE + IMPLEMENTATION AUTHORITY TYPE
-- --------------------------------------------------------------------------
ALTER TABLE retail.retail_scraper_assets
  ADD COLUMN IF NOT EXISTS implementation_authority_type text
    CHECK(implementation_authority_type IS NULL OR implementation_authority_type IN ('file','package_tree')),
  ADD COLUMN IF NOT EXISTS source_process_run_id uuid
    REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS source_correlation_id text,
  ADD COLUMN IF NOT EXISTS supersedes_asset_id uuid
    REFERENCES retail.retail_scraper_assets(id) ON DELETE RESTRICT;

UPDATE retail.retail_scraper_assets
SET implementation_authority_type=
  CASE
    WHEN implementation_kind IN ('script','worker','test_harness') THEN 'file'
    ELSE 'package_tree'
  END
WHERE implementation_authority_type IS NULL;

ALTER TABLE retail.retail_scraper_assets
  ALTER COLUMN implementation_authority_type SET NOT NULL;

ALTER TABLE retail.retail_scraper_contracts
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS source_process_run_id uuid
    REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS source_correlation_id text,
  ADD COLUMN IF NOT EXISTS supersedes_contract_id uuid
    REFERENCES retail.retail_scraper_contracts(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS status_reason text;

-- Integration matrix mirrors the terminal RETIRED state.
ALTER TABLE retail.r1b_adapter_integration_matrix
  DROP CONSTRAINT IF EXISTS r1b_adapter_integration_matrix_r1b_certification_status_check;

ALTER TABLE retail.r1b_adapter_integration_matrix
  ADD CONSTRAINT r1b_adapter_integration_matrix_r1b_certification_status_check
  CHECK(r1b_certification_status IN(
    'inventory_pending','contract_verified','qa_passed',
    'certified_for_r1','test_only','blocked','retired'
  ));

-- --------------------------------------------------------------------------
-- HASH DOCUMENTS
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1b_scraper_asset_evidence_document(
  p_row retail.retail_scraper_assets
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'platform_id',p_row.platform_id,
    'asset_code',p_row.asset_code,
    'implementation_root',p_row.implementation_root,
    'implementation_kind',p_row.implementation_kind,
    'implementation_authority_type',p_row.implementation_authority_type,
    'repository_url',p_row.repository_url,
    'repository_branch',p_row.repository_branch,
    'git_commit_sha',p_row.git_commit_sha,
    'package_tree_sha256',p_row.package_tree_sha256,
    'entrypoint_ref',p_row.entrypoint_ref,
    'entrypoint_sha256',p_row.entrypoint_sha256,
    'package_json_ref',p_row.package_json_ref,
    'package_json_sha256',p_row.package_json_sha256,
    'execution_command',p_row.execution_command,
    'test_command',p_row.test_command,
    'build_command',p_row.build_command,
    'source_files_json',p_row.source_files_json,
    'test_files_json',p_row.test_files_json,
    'sql_files_json',p_row.sql_files_json,
    'verification_evidence_json',p_row.verification_evidence_json
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1b_scraper_contract_document(
  p_row retail.retail_scraper_contracts
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'scraper_asset_id',p_row.scraper_asset_id,
    'adapter_id',p_row.adapter_id,
    'contract_version',p_row.contract_version,
    'discovery_type',p_row.discovery_type,
    'transport',p_row.transport,
    'compile_modes',p_row.compile_modes,
    'field_map',p_row.field_map,
    'required_fields',p_row.required_fields,
    'supports_keyword_search',p_row.supports_keyword_search,
    'supports_category_search',p_row.supports_category_search,
    'supports_product_url',p_row.supports_product_url,
    'supports_store_id',p_row.supports_store_id,
    'supports_postal_code',p_row.supports_postal_code,
    'supports_region',p_row.supports_region,
    'supports_result_limit',p_row.supports_result_limit,
    'collection_methods',p_row.collection_methods,
    'source_types',p_row.source_types,
    'brightdata_dataset_ids',p_row.brightdata_dataset_ids,
    'brightdata_unlocker_zones',p_row.brightdata_unlocker_zones,
    'db_ingest_targets',p_row.db_ingest_targets,
    'interface_evidence_json',p_row.interface_evidence_json
  )
$$;

-- --------------------------------------------------------------------------
-- DB INGEST TARGET VALIDATION
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1b_validate_db_ingest_targets(
  p_platform_id uuid,
  p_targets jsonb
)
RETURNS void
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  v_platform_code text;
  v_target text;
  v_rel regclass;
  v_schema text;
  v_table text;
  v_allowed_prefixes text[];
  v_shared constant text[] := ARRAY[
    'retail.raw_product_captures',
    'retail.retail_products',
    'retail.product_price_history',
    'retail.product_inventory_history',
    'retail.retail_offer_snapshots',
    'retail.current_retail_offers',
    'retail.product_evidence_artifacts',
    'retail.data_quality_events',
    'retail.erip_source_exports',
    'retail.collection_runs',
    'retail.collection_run_items',
    'retail.ingest_dead_letters',
    'retail.product_discount_qualifications',
    'retail.collection_source_health',
    'retail.collection_source_verifications',
    'retail.platform_health_rollups'
  ];
BEGIN
  IF jsonb_typeof(p_targets)<>'array' OR jsonb_array_length(p_targets)=0 THEN
    RAISE EXCEPTION 'db_ingest_targets must be a non-empty JSON array';
  END IF;

  SELECT platform_code INTO v_platform_code
  FROM retail.retail_platforms
  WHERE id=p_platform_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Platform missing for ingest-target validation';
  END IF;

  v_allowed_prefixes:=CASE v_platform_code
    WHEN 'bhphoto' THEN ARRAY['bhphoto_','bhphotovideo_']
    WHEN 'bhphotovideo' THEN ARRAY['bhphoto_','bhphotovideo_']
    WHEN 'best_buy' THEN ARRAY['bestbuy_','best_buy_']
    ELSE ARRAY[v_platform_code||'_']
  END;

  FOR v_target IN
    SELECT jsonb_array_elements_text(p_targets)
  LOOP
    IF v_target !~ '^retail\.[a-z0-9_]+$' THEN
      RAISE EXCEPTION 'Invalid db_ingest_target format: %',v_target;
    END IF;

    v_rel:=to_regclass(v_target);
    IF v_rel IS NULL THEN
      RAISE EXCEPTION 'db_ingest_target does not exist: %',v_target;
    END IF;

    SELECT n.nspname,c.relname
      INTO v_schema,v_table
    FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE c.oid=v_rel;

    IF v_schema<>'retail' THEN
      RAISE EXCEPTION 'db_ingest_target must be in retail schema: %',v_target;
    END IF;

    IF NOT (v_target = ANY(v_shared))
       AND NOT EXISTS(
         SELECT 1
         FROM unnest(v_allowed_prefixes) p(prefix)
         WHERE v_table LIKE p.prefix||'%'
       ) THEN
      RAISE EXCEPTION
        'Cross-platform ingest target blocked. platform=% target=%',
        v_platform_code,v_target;
    END IF;
  END LOOP;
END $$;

-- --------------------------------------------------------------------------
-- ASSET HASH RECOMPUTATION + IMMUTABILITY
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1b_prepare_scraper_asset()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.verification_evidence_sha256:=
    retail.r1b_sha256_jsonb(NEW.verification_evidence_json);
  NEW.updated_at:=now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1b_prepare_scraper_asset ON retail.retail_scraper_assets;
CREATE TRIGGER trg_r1b_prepare_scraper_asset
BEFORE INSERT OR UPDATE ON retail.retail_scraper_assets
FOR EACH ROW EXECUTE FUNCTION retail.r1b_prepare_scraper_asset();

CREATE OR REPLACE FUNCTION retail.r1b_scraper_asset_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'Verified scraper assets cannot be deleted; supersede/retire them';
  END IF;

  IF OLD.discovery_status IN ('verified','superseded','retired') THEN
    IF (to_jsonb(NEW)-ARRAY['discovery_status','updated_at'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['discovery_status','updated_at']) THEN
      RAISE EXCEPTION
        'Verified scraper asset content is immutable; inventory a new asset version';
    END IF;

    IF OLD.discovery_status='verified'
       AND NEW.discovery_status NOT IN ('verified','superseded','retired') THEN
      RAISE EXCEPTION 'Invalid scraper asset transition % -> %',
        OLD.discovery_status,NEW.discovery_status;
    END IF;

    IF OLD.discovery_status IN ('superseded','retired')
       AND NEW.discovery_status<>OLD.discovery_status THEN
      RAISE EXCEPTION 'Superseded/retired scraper asset is terminal';
    END IF;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1b_scraper_asset_immutable ON retail.retail_scraper_assets;
CREATE TRIGGER trg_r1b_scraper_asset_immutable
BEFORE UPDATE OR DELETE ON retail.retail_scraper_assets
FOR EACH ROW EXECUTE FUNCTION retail.r1b_scraper_asset_immutable();

-- --------------------------------------------------------------------------
-- CONTRACT HASH RECOMPUTATION + LIFECYCLE IMMUTABILITY
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1b_prepare_scraper_contract()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  v_platform_id uuid;
BEGIN
  SELECT a.platform_id INTO v_platform_id
  FROM retail.retail_search_adapters a
  JOIN retail.retail_scraper_assets s
    ON s.id=NEW.scraper_asset_id
   AND s.platform_id=a.platform_id
  WHERE a.id=NEW.adapter_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Scraper contract adapter/asset platform mismatch';
  END IF;

  PERFORM retail.r1b_validate_db_ingest_targets(
    v_platform_id,NEW.db_ingest_targets
  );

  NEW.interface_evidence_sha256:=
    retail.r1b_sha256_jsonb(NEW.interface_evidence_json);

  NEW.contract_document:=
    retail.r1b_scraper_contract_document(NEW);

  NEW.contract_sha256:=
    retail.r1b_sha256_jsonb(NEW.contract_document);

  NEW.updated_at:=now();

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1b_prepare_scraper_contract ON retail.retail_scraper_contracts;
CREATE TRIGGER trg_r1b_prepare_scraper_contract
BEFORE INSERT OR UPDATE ON retail.retail_scraper_contracts
FOR EACH ROW EXECUTE FUNCTION retail.r1b_prepare_scraper_contract();

CREATE OR REPLACE FUNCTION retail.r1b_scraper_contract_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_business_changed boolean;
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'Scraper contracts cannot be deleted; block/retire them';
  END IF;

  v_business_changed:=
    (to_jsonb(NEW)-ARRAY[
      'certification_status','certified_by','certified_at',
      'updated_at','status_reason',
      'source_process_run_id','source_correlation_id'
    ])
    IS DISTINCT FROM
    (to_jsonb(OLD)-ARRAY[
      'certification_status','certified_by','certified_at',
      'updated_at','status_reason',
      'source_process_run_id','source_correlation_id'
    ]);

  IF OLD.certification_status IN (
    'contract_verified','qa_passed','certified_for_r1',
    'test_only','blocked','retired'
  ) AND v_business_changed THEN
    RAISE EXCEPTION
      'Verified scraper contract content is immutable; register a new contract_version';
  END IF;

  IF OLD.certification_status='retired'
     AND NEW.certification_status<>'retired' THEN
    RAISE EXCEPTION 'Retired scraper contract is terminal';
  END IF;

  IF OLD.certification_status='blocked'
     AND NEW.certification_status NOT IN ('blocked','retired') THEN
    RAISE EXCEPTION 'Blocked scraper contract cannot be reactivated; create new version';
  END IF;

  IF OLD.certification_status='test_only'
     AND NEW.certification_status NOT IN ('test_only','blocked','retired') THEN
    RAISE EXCEPTION 'Test-only scraper contract cannot be promoted to production';
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1b_scraper_contract_immutable ON retail.retail_scraper_contracts;
CREATE TRIGGER trg_r1b_scraper_contract_immutable
BEFORE UPDATE OR DELETE ON retail.retail_scraper_contracts
FOR EACH ROW EXECUTE FUNCTION retail.r1b_scraper_contract_immutable();

-- --------------------------------------------------------------------------
-- GOVERNED CONTRACT REGISTRATION / TRANSITION
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1b_register_scraper_contract(
  p_scraper_asset_id uuid,
  p_adapter_id uuid,
  p_contract_version text,
  p_contract_json jsonb,
  p_interface_evidence jsonb,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text,
  p_supersedes_contract_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  v_asset record;
  v_adapter record;
  v_id uuid;
  v_test_only boolean;
BEGIN
  IF NULLIF(btrim(p_contract_version),'') IS NULL THEN
    RAISE EXCEPTION 'contract_version required';
  END IF;
  IF jsonb_typeof(p_contract_json)<>'object'
     OR jsonb_typeof(p_interface_evidence)<>'object' THEN
    RAISE EXCEPTION 'contract/evidence must be JSON objects';
  END IF;

  SELECT * INTO v_asset
  FROM retail.retail_scraper_assets
  WHERE id=p_scraper_asset_id
    AND discovery_status='verified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Verified scraper asset required';
  END IF;

  SELECT * INTO v_adapter
  FROM retail.retail_search_adapters
  WHERE id=p_adapter_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Adapter missing';
  END IF;

  IF v_adapter.platform_id<>v_asset.platform_id THEN
    RAISE EXCEPTION 'Adapter/asset platform mismatch';
  END IF;

  IF v_adapter.certification_status='certified_dynamic_search' THEN
    RAISE EXCEPTION
      'Cannot retrofit scraper authority onto a certified adapter. Create a new adapter_version first.';
  END IF;

  v_test_only:=COALESCE((p_contract_json->>'test_only')::boolean,false)
               OR v_asset.implementation_kind='test_harness';

  INSERT INTO retail.retail_scraper_contracts(
    scraper_asset_id,adapter_id,contract_version,
    discovery_type,transport,
    compile_modes,field_map,required_fields,
    supports_keyword_search,supports_category_search,
    supports_product_url,supports_store_id,
    supports_postal_code,supports_region,supports_result_limit,
    collection_methods,source_types,
    brightdata_dataset_ids,brightdata_unlocker_zones,
    db_ingest_targets,
    interface_evidence_json,interface_evidence_sha256,
    contract_document,contract_sha256,
    certification_status,
    source_process_run_id,source_correlation_id,
    supersedes_contract_id
  )
  VALUES(
    p_scraper_asset_id,p_adapter_id,p_contract_version,
    COALESCE(NULLIF(p_contract_json->>'discovery_type',''),'unknown'),
    COALESCE(NULLIF(p_contract_json->>'transport',''),'env'),
    COALESCE(p_contract_json->'compile_modes','[]'::jsonb),
    COALESCE(p_contract_json->'field_map','{}'::jsonb),
    COALESCE(p_contract_json->'required_fields','[]'::jsonb),
    COALESCE((p_contract_json->>'supports_keyword_search')::boolean,false),
    COALESCE((p_contract_json->>'supports_category_search')::boolean,false),
    COALESCE((p_contract_json->>'supports_product_url')::boolean,false),
    COALESCE((p_contract_json->>'supports_store_id')::boolean,false),
    COALESCE((p_contract_json->>'supports_postal_code')::boolean,false),
    COALESCE((p_contract_json->>'supports_region')::boolean,false),
    COALESCE((p_contract_json->>'supports_result_limit')::boolean,false),
    COALESCE(p_contract_json->'collection_methods','[]'::jsonb),
    COALESCE(p_contract_json->'source_types','[]'::jsonb),
    COALESCE(p_contract_json->'brightdata_dataset_ids','[]'::jsonb),
    COALESCE(p_contract_json->'brightdata_unlocker_zones','[]'::jsonb),
    COALESCE(p_contract_json->'db_ingest_targets','[]'::jsonb),
    p_interface_evidence,repeat('0',64),
    '{}'::jsonb,repeat('0',64),
    CASE WHEN v_test_only THEN 'test_only' ELSE 'inventory_pending' END,
    p_process_run_id,p_correlation_id,p_supersedes_contract_id
  )
  RETURNING id INTO v_id;

  -- The adapter is an R1-facing representation of this exact existing
  -- scraper contract. Populate it BEFORE certification. The core adapter
  -- prepare trigger will recompute input/capability hashes.
  UPDATE retail.retail_search_adapters
  SET scraper_asset_id=p_scraper_asset_id,
      scraper_contract_id=v_id,
      implementation_ref=v_asset.implementation_root,
      implementation_sha256=
        CASE
          WHEN v_asset.implementation_authority_type='package_tree'
            THEN v_asset.package_tree_sha256
          ELSE COALESCE(v_asset.entrypoint_sha256,v_asset.package_tree_sha256)
        END,
      git_commit_sha=COALESCE(v_asset.git_commit_sha,git_commit_sha),

      supports_keyword_search=
        COALESCE((p_contract_json->>'supports_keyword_search')::boolean,false),
      supports_product_url=
        COALESCE((p_contract_json->>'supports_product_url')::boolean,false),
      supports_category_search=
        COALESCE((p_contract_json->>'supports_category_search')::boolean,false),
      supports_store_id=
        COALESCE((p_contract_json->>'supports_store_id')::boolean,false),
      supports_postal_code=
        COALESCE((p_contract_json->>'supports_postal_code')::boolean,false),
      supports_region=
        COALESCE((p_contract_json->>'supports_region')::boolean,false),
      supports_result_limit=
        COALESCE((p_contract_json->>'supports_result_limit')::boolean,false),

      supported_collection_methods=
        COALESCE(p_contract_json->'collection_methods','[]'::jsonb),
      supports_all_collection_methods=
        COALESCE((p_contract_json->>'supports_all_collection_methods')::boolean,false),
      supported_source_types=
        COALESCE(p_contract_json->'source_types','[]'::jsonb),
      supports_all_source_types=
        COALESCE((p_contract_json->>'supports_all_source_types')::boolean,false),

      input_contract_json=jsonb_build_object(
        'transport',COALESCE(NULLIF(p_contract_json->>'transport',''),'env'),
        'compile_modes',COALESCE(p_contract_json->'compile_modes','[]'::jsonb),
        'field_map',COALESCE(p_contract_json->'field_map','{}'::jsonb),
        'required_fields',COALESCE(p_contract_json->'required_fields','[]'::jsonb)
      )
  WHERE id=p_adapter_id
    AND certification_status IN ('uncertified','test_only','partially_dynamic');

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Adapter became ineligible while attaching scraper contract. Certified adapter versions must be replaced with a new version.';
  END IF;

  UPDATE retail.r1b_adapter_integration_matrix
  SET adapter_id=p_adapter_id,
      scraper_asset_id=p_scraper_asset_id,
      scraper_contract_id=v_id,
      r1b_certification_status=
        CASE WHEN v_test_only THEN 'test_only' ELSE 'inventory_pending' END,
      updated_at=now()
  WHERE platform_id=v_asset.platform_id;

  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION retail.r1b_transition_scraper_contract(
  p_contract_id uuid,
  p_new_status text,
  p_process_run_id uuid,
  p_correlation_id text,
  p_actor text,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,retail,arb
AS $$
DECLARE
  c record;
  v_allowed boolean:=false;
BEGIN
  SELECT * INTO c
  FROM retail.retail_scraper_contracts
  WHERE id=p_contract_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Scraper contract missing';
  END IF;

  v_allowed:=CASE c.certification_status
    WHEN 'inventory_pending' THEN p_new_status IN ('contract_verified','blocked','retired')
    WHEN 'contract_verified' THEN p_new_status IN ('qa_passed','blocked','retired')
    WHEN 'qa_passed' THEN p_new_status IN ('certified_for_r1','blocked','retired')
    WHEN 'certified_for_r1' THEN p_new_status IN ('blocked','retired')
    WHEN 'test_only' THEN p_new_status IN ('blocked','retired')
    WHEN 'blocked' THEN p_new_status='retired'
    WHEN 'retired' THEN false
    ELSE false
  END;

  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Invalid scraper contract transition % -> %',
      c.certification_status,p_new_status;
  END IF;

  IF p_new_status IN ('contract_verified','qa_passed','certified_for_r1') THEN
    IF c.interface_evidence_sha256<>
       retail.r1b_sha256_jsonb(c.interface_evidence_json) THEN
      RAISE EXCEPTION 'Interface evidence hash mismatch';
    END IF;

    IF c.contract_sha256<>
       retail.r1b_sha256_jsonb(c.contract_document) THEN
      RAISE EXCEPTION 'Scraper contract hash mismatch';
    END IF;

    IF NOT EXISTS(
      SELECT 1 FROM retail.retail_scraper_assets s
      WHERE s.id=c.scraper_asset_id
        AND s.discovery_status='verified'
        AND s.verification_evidence_sha256=
            retail.r1b_sha256_jsonb(s.verification_evidence_json)
    ) THEN
      RAISE EXCEPTION 'Verified/current scraper asset required';
    END IF;
  END IF;

  UPDATE retail.retail_scraper_contracts
  SET certification_status=p_new_status,
      certified_by=CASE WHEN p_new_status='certified_for_r1' THEN p_actor ELSE certified_by END,
      certified_at=CASE WHEN p_new_status='certified_for_r1' THEN now() ELSE certified_at END,
      status_reason=p_reason,
      source_process_run_id=p_process_run_id,
      source_correlation_id=p_correlation_id,
      updated_at=now()
  WHERE id=p_contract_id;

  UPDATE retail.r1b_adapter_integration_matrix
  SET r1b_certification_status=p_new_status,
      updated_at=now()
  WHERE scraper_contract_id=p_contract_id;
END $$;

-- --------------------------------------------------------------------------
-- SCRAPER PRE-CERTIFICATION CURRENTNESS
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1b_scraper_contract_prepared_for_adapter(
  p_adapter_id uuid
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      a.scraper_asset_id=s.id
      AND a.scraper_contract_id=c.id
      AND s.platform_id=a.platform_id
      AND s.discovery_status='verified'
      AND s.verification_evidence_sha256=
          retail.r1b_sha256_jsonb(s.verification_evidence_json)
      AND c.adapter_id=a.id
      AND c.scraper_asset_id=s.id
      AND c.certification_status='certified_for_r1'
      AND c.interface_evidence_sha256=
          retail.r1b_sha256_jsonb(c.interface_evidence_json)
      AND c.contract_sha256=
          retail.r1b_sha256_jsonb(c.contract_document)
    FROM retail.retail_search_adapters a
    JOIN retail.retail_scraper_assets s ON s.id=a.scraper_asset_id
    JOIN retail.retail_scraper_contracts c ON c.id=a.scraper_contract_id
    WHERE a.id=p_adapter_id
  ),false)
$$;

CREATE OR REPLACE FUNCTION retail.r1b_scraper_contract_is_current(
  p_adapter_id uuid
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT COALESCE((
    SELECT
      a.certification_status='certified_dynamic_search'
      AND retail.r1b_scraper_contract_prepared_for_adapter(a.id)=true
    FROM retail.retail_search_adapters a
    WHERE a.id=p_adapter_id
  ),false)
$$;

CREATE OR REPLACE FUNCTION retail.r1b_adapter_execution_ready(
  p_adapter_id uuid
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  SELECT
    retail.r1b_adapter_is_certified_current(p_adapter_id)=true
    AND retail.r1b_scraper_contract_is_current(p_adapter_id)=true
$$;

-- --------------------------------------------------------------------------
-- CERTIFICATION FINGERPRINT NOW BINDS SCRAPER ASSET + CONTRACT IDS
-- Existing already-certified adapter versions become stale/fail-closed
-- until a new adapter_version is created and certified with scraper authority.
-- --------------------------------------------------------------------------
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
    'scraper_asset_id',p_row.scraper_asset_id,
    'scraper_contract_id',p_row.scraper_contract_id,
    'certification_evidence_hash',p_row.certification_evidence_hash
  )
$$;

CREATE OR REPLACE FUNCTION retail.r1b_adapter_authority_document(
  p_adapter_id uuid
)
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
    'certification_fingerprint_hash',a.certification_fingerprint_hash,

    'scraper_asset_id',s.id,
    'scraper_asset_authority_type',s.implementation_authority_type,
    'scraper_package_tree_sha256',s.package_tree_sha256,
    'scraper_entrypoint_sha256',s.entrypoint_sha256,
    'scraper_verification_evidence_sha256',s.verification_evidence_sha256,
    'scraper_discovery_status',s.discovery_status,

    'scraper_contract_id',c.id,
    'scraper_contract_version',c.contract_version,
    'scraper_contract_sha256',c.contract_sha256,
    'scraper_interface_evidence_sha256',c.interface_evidence_sha256,
    'scraper_contract_status',c.certification_status
  )
  FROM retail.retail_search_adapters a
  LEFT JOIN retail.retail_scraper_assets s ON s.id=a.scraper_asset_id
  LEFT JOIN retail.retail_scraper_contracts c ON c.id=a.scraper_contract_id
  WHERE a.id=p_adapter_id
$$;

-- --------------------------------------------------------------------------
-- ATOMIC ADAPTER CERTIFICATION REQUIRES SCRAPER AUTHORITY FIRST
-- --------------------------------------------------------------------------
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

  IF retail.r1b_scraper_contract_prepared_for_adapter(p_adapter_id) IS NOT TRUE THEN
    RAISE EXCEPTION
      'Adapter certification blocked: exact existing scraper asset/contract is not certified/current';
  END IF;

  UPDATE retail.retail_search_adapters
  SET certification_status='certified_dynamic_search',
      certification_evidence_hash=p_evidence_sha256,
      git_commit_sha=COALESCE(p_git_commit_sha,git_commit_sha),
      certified_by=p_certifier,
      certified_at=now()
  WHERE id=p_adapter_id
    AND certification_status IN ('uncertified','partially_dynamic');

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Adapter missing/ineligible. Existing certified adapter versions cannot be retrofitted; create a new adapter_version.';
  END IF;

  IF retail.r1b_adapter_execution_ready(p_adapter_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Adapter certification failed closed after scraper binding';
  END IF;
END $$;

-- --------------------------------------------------------------------------
-- ROUTE AUTHORITY NOW REQUIRES EXECUTION-READY SCRAPER AUTHORITY
-- Adapter snapshot hash automatically includes scraper asset/contract hashes
-- because r1b_adapter_authority_document() was upgraded above.
-- --------------------------------------------------------------------------
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
      AND retail.r1b_adapter_execution_ready(a.id)=true
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
      AND (r.location_id IS NULL OR l.location_status='approved')
      AND (l.id IS NULL OR l.location_type<>'store' OR l.platform_id=r.platform_id)
      AND (s.source_scope NOT IN ('store','postal_code') OR r.location_id IS NOT NULL)
      AND (s.required_store_id IS NULL OR l.retailer_store_id IS NOT DISTINCT FROM s.required_store_id)
      AND (s.required_postal_code IS NULL OR l.postal_code IS NOT DISTINCT FROM s.required_postal_code)
      AND (l.id IS NULL OR l.location_type<>'store' OR a.supports_store_id=true)
      AND (l.id IS NULL OR l.location_type<>'postal_code' OR a.supports_postal_code=true)
      AND (l.id IS NULL OR l.location_type<>'region' OR a.supports_region=true)
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
      ON e.target_id=r.target_id
     AND e.revision_id=r.r1a_revision_id
    JOIN retail.retail_platforms p ON p.id=r.platform_id
    JOIN retail.platform_collection_sources s ON s.id=r.collection_source_id
    LEFT JOIN retail.platform_collection_configs c ON c.id=s.config_id
    JOIN retail.retail_search_adapters a ON a.id=r.adapter_id
    LEFT JOIN retail.search_locations l ON l.id=r.location_id
    WHERE r.id=p_route_id
  ),false)
$$;

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
        AND retail.r1b_adapter_execution_ready(a.id)=true
    ) THEN
      RAISE EXCEPTION
        'Route approval blocked: adapter or existing scraper authority is not execution-ready';
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

-- --------------------------------------------------------------------------
-- RUNTIME ATTESTATION: FILE OR PACKAGE TREE
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retail.r1b_assert_runtime_adapter(
  p_adapter_id uuid,
  p_observed_implementation_sha256 text
)
RETURNS void
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
DECLARE
  v_expected text;
BEGIN
  IF p_observed_implementation_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R1B runtime attestation requires lowercase SHA-256';
  END IF;

  SELECT
    CASE
      WHEN s.implementation_authority_type='package_tree'
        THEN s.package_tree_sha256
      ELSE COALESCE(s.entrypoint_sha256,a.implementation_sha256)
    END
  INTO v_expected
  FROM retail.retail_search_adapters a
  JOIN retail.retail_scraper_assets s ON s.id=a.scraper_asset_id
  WHERE a.id=p_adapter_id
    AND retail.r1b_adapter_execution_ready(a.id)=true;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'R1B runtime attestation blocked: adapter/scraper authority is not execution-ready';
  END IF;

  IF v_expected IS DISTINCT FROM p_observed_implementation_sha256 THEN
    RAISE EXCEPTION
      'R1B runtime attestation blocked: deployed scraper artifact/package SHA mismatch';
  END IF;
END $$;

-- --------------------------------------------------------------------------
-- NON-EMPTY / EXPLICIT PRODUCTION SET READINESS
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.r1b_production_scraper_scope(
  platform_id uuid PRIMARY KEY REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  is_required boolean NOT NULL DEFAULT true,
  required_by text NOT NULL,
  required_at timestamptz NOT NULL DEFAULT now(),
  notes text
);

CREATE OR REPLACE FUNCTION retail.r1b_scraper_integration_readiness()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,retail
AS $$
  WITH x AS (
    SELECT
      count(*) FILTER(WHERE expectation_status='known') expected_known,
      count(*) FILTER(WHERE expectation_status='missing_identity') unidentified,
      count(*) expected_total
    FROM retail.r1b_expected_scraper_inventory
  ),
  m AS (
    SELECT
      count(*) FILTER(WHERE inventory_status IN('discovered','verified')) inventoried,
      count(*) FILTER(WHERE inventory_status='verified') verified,
      count(*) FILTER(WHERE r1b_certification_status='certified_for_r1') certified_for_r1,
      count(*) FILTER(WHERE r1b_certification_status='test_only') test_only
    FROM retail.r1b_adapter_integration_matrix
  ),
  s AS (
    SELECT
      count(*) FILTER(WHERE is_required) required_platforms,
      count(*) FILTER(
        WHERE is_required AND EXISTS(
          SELECT 1
          FROM retail.retail_search_adapters a
          WHERE a.platform_id=ps.platform_id
            AND retail.r1b_adapter_execution_ready(a.id)=true
        )
      ) required_platforms_ready
    FROM retail.r1b_production_scraper_scope ps
  )
  SELECT jsonb_build_object(
    'expected_total',x.expected_total,
    'expected_known',x.expected_known,
    'unidentified',x.unidentified,
    'inventoried',COALESCE(m.inventoried,0),
    'verified',COALESCE(m.verified,0),
    'certified_for_r1',COALESCE(m.certified_for_r1,0),
    'test_only',COALESCE(m.test_only,0),
    'required_platforms',COALESCE(s.required_platforms,0),
    'required_platforms_ready',COALESCE(s.required_platforms_ready,0),
    'nonempty_production_universe',COALESCE(m.certified_for_r1,0)>0,
    'production_scope_nonempty',COALESCE(s.required_platforms,0)>0,
    'production_scope_ready',
      COALESCE(s.required_platforms,0)>0
      AND COALESCE(s.required_platforms_ready,0)=COALESCE(s.required_platforms,0),
    'all_known_inventoried',COALESCE(m.inventoried,0)>=x.expected_known,
    'full_22_identified',x.unidentified=0
  )
  FROM x,m,s
$$;

-- --------------------------------------------------------------------------
-- PUBLIC EXECUTE / DML HARDENING
-- --------------------------------------------------------------------------
REVOKE ALL ON FUNCTION retail.r1b_register_scraper_contract(
  uuid,uuid,text,jsonb,jsonb,uuid,text,text,uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1b_transition_scraper_contract(
  uuid,text,uuid,text,text,text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1b_validate_db_ingest_targets(uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1b_scraper_contract_prepared_for_adapter(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1b_scraper_contract_is_current(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1b_adapter_execution_ready(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1b_assert_runtime_adapter(uuid,text) FROM PUBLIC;

REVOKE INSERT,UPDATE,DELETE ON retail.retail_scraper_assets FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE ON retail.retail_scraper_contracts FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE ON retail.r1b_adapter_integration_matrix FROM PUBLIC;
REVOKE INSERT,UPDATE,DELETE ON retail.r1b_production_scraper_scope FROM PUBLIC;

COMMIT;
