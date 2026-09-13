BEGIN;
CREATE SCHEMA IF NOT EXISTS retail;
CREATE SCHEMA IF NOT EXISTS retail_audit;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- TCDS R1B Existing Scraper Integration Authority A1
-- R1 orchestrates/certifies existing tested retailer collectors; it does not replace them.
DO $$
BEGIN
  IF to_regclass('retail.r1b_schema_state') IS NULL OR NOT EXISTS(
    SELECT 1 FROM retail.r1b_schema_state WHERE singleton=true AND schema_version='3.0.0'
  ) THEN RAISE EXCEPTION 'R1B scraper integration requires R1B V3 schema 3.0.0'; END IF;
  IF to_regclass('retail.retail_search_adapters') IS NULL OR to_regclass('retail.retail_platforms') IS NULL THEN
    RAISE EXCEPTION 'R1B adapter/platform authority missing';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS retail.r1b_adapter_integration_state(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton=true),
  integration_version text NOT NULL,
  expected_scraper_count integer NOT NULL CHECK(expected_scraper_count>0),
  repository_url text NOT NULL,
  repository_branch text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user
);
INSERT INTO retail.r1b_adapter_integration_state(singleton,integration_version,expected_scraper_count,repository_url,repository_branch)
VALUES(true,'1.0.0',22,'https://github.com/latinabeautycollection/TCDS_BOT_CREATION','main')
ON CONFLICT(singleton) DO UPDATE SET integration_version=EXCLUDED.integration_version,expected_scraper_count=EXCLUDED.expected_scraper_count,repository_url=EXCLUDED.repository_url,repository_branch=EXCLUDED.repository_branch;

CREATE TABLE IF NOT EXISTS retail.retail_scraper_assets(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  asset_code text NOT NULL CHECK(asset_code~'^[a-z0-9_]+$'),
  implementation_root text NOT NULL,
  implementation_kind text NOT NULL CHECK(implementation_kind IN('package','script','worker','test_harness')),
  repository_url text NOT NULL,
  repository_branch text NOT NULL,
  git_commit_sha text CHECK(git_commit_sha IS NULL OR git_commit_sha~'^[0-9a-f]{7,64}$'),
  package_tree_sha256 text NOT NULL CHECK(package_tree_sha256~'^[0-9a-f]{64}$'),
  entrypoint_ref text,
  entrypoint_sha256 text CHECK(entrypoint_sha256 IS NULL OR entrypoint_sha256~'^[0-9a-f]{64}$'),
  package_json_ref text,
  package_json_sha256 text CHECK(package_json_sha256 IS NULL OR package_json_sha256~'^[0-9a-f]{64}$'),
  execution_command text,test_command text,build_command text,
  source_files_json jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(source_files_json)='array'),
  test_files_json jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(test_files_json)='array'),
  sql_files_json jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(sql_files_json)='array'),
  discovery_status text NOT NULL DEFAULT 'discovered' CHECK(discovery_status IN('expected','discovered','verified','missing','superseded','retired')),
  verification_evidence_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(verification_evidence_json)='object'),
  verification_evidence_sha256 text CHECK(verification_evidence_sha256 IS NULL OR verification_evidence_sha256~'^[0-9a-f]{64}$'),
  verified_by text,verified_at timestamptz,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(platform_id,asset_code,package_tree_sha256)
);

CREATE TABLE IF NOT EXISTS retail.retail_scraper_contracts(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scraper_asset_id uuid NOT NULL REFERENCES retail.retail_scraper_assets(id) ON DELETE RESTRICT,
  adapter_id uuid NOT NULL REFERENCES retail.retail_search_adapters(id) ON DELETE RESTRICT,
  contract_version text NOT NULL,
  discovery_type text NOT NULL CHECK(discovery_type IN('keyword','category','product_url','store_inventory','category_to_pdp','mixed','unknown')),
  transport text NOT NULL CHECK(transport IN('env','argv','json','query','hybrid')),
  compile_modes jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(compile_modes)='array'),
  field_map jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(field_map)='object'),
  required_fields jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(required_fields)='array'),
  supports_keyword_search boolean NOT NULL DEFAULT false,supports_category_search boolean NOT NULL DEFAULT false,
  supports_product_url boolean NOT NULL DEFAULT false,supports_store_id boolean NOT NULL DEFAULT false,
  supports_postal_code boolean NOT NULL DEFAULT false,supports_region boolean NOT NULL DEFAULT false,
  supports_result_limit boolean NOT NULL DEFAULT false,
  collection_methods jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(collection_methods)='array'),
  source_types jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(source_types)='array'),
  brightdata_dataset_ids jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(brightdata_dataset_ids)='array'),
  brightdata_unlocker_zones jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(brightdata_unlocker_zones)='array'),
  db_ingest_targets jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(db_ingest_targets)='array'),
  interface_evidence_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(interface_evidence_json)='object'),
  interface_evidence_sha256 text NOT NULL CHECK(interface_evidence_sha256~'^[0-9a-f]{64}$'),
  contract_document jsonb NOT NULL CHECK(jsonb_typeof(contract_document)='object'),
  contract_sha256 text NOT NULL CHECK(contract_sha256~'^[0-9a-f]{64}$'),
  certification_status text NOT NULL DEFAULT 'inventory_pending' CHECK(certification_status IN('inventory_pending','contract_verified','qa_passed','certified_for_r1','test_only','blocked','retired')),
  certified_by text,certified_at timestamptz,created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(scraper_asset_id,adapter_id,contract_version)
);

CREATE TABLE IF NOT EXISTS retail.r1b_adapter_integration_matrix(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id) ON DELETE RESTRICT,
  scraper_asset_id uuid REFERENCES retail.retail_scraper_assets(id) ON DELETE RESTRICT,
  scraper_contract_id uuid REFERENCES retail.retail_scraper_contracts(id) ON DELETE RESTRICT,
  adapter_id uuid REFERENCES retail.retail_search_adapters(id) ON DELETE RESTRICT,
  expected_slot integer NOT NULL CHECK(expected_slot BETWEEN 1 AND 22),
  platform_code text NOT NULL,implementation_root text NOT NULL,
  inventory_status text NOT NULL DEFAULT 'expected' CHECK(inventory_status IN('expected','discovered','verified','missing')),
  r1b_certification_status text NOT NULL DEFAULT 'inventory_pending' CHECK(r1b_certification_status IN('inventory_pending','contract_verified','qa_passed','certified_for_r1','test_only','blocked')),
  notes text,updated_at timestamptz NOT NULL DEFAULT now(),UNIQUE(expected_slot),UNIQUE(platform_id,implementation_root)
);

CREATE TABLE IF NOT EXISTS retail.r1b_expected_scraper_inventory(
  expected_slot integer PRIMARY KEY CHECK(expected_slot BETWEEN 1 AND 22),
  platform_code text,platform_code_candidates jsonb NOT NULL DEFAULT '[]'::jsonb,
  implementation_root text,implementation_kind text,
  expectation_status text NOT NULL CHECK(expectation_status IN('known','missing_identity')),notes text
);

INSERT INTO retail.r1b_expected_scraper_inventory(expected_slot,platform_code,platform_code_candidates,implementation_root,implementation_kind,expectation_status,notes) VALUES
(1,'adorama','["adorama"]','incoming/adorama','package','known','Existing retailer package'),
(2,'amazon','["amazon"]','incoming/amazon','package','known','Existing retailer package'),
(3,'bhphoto','["bhphoto","bhphotovideo"]','incoming/bhphoto','package','known','Existing retailer package; platform alias allowed'),
(4,'bjs','["bjs"]','incoming/bjs','package','known','Existing retailer package'),
(5,'cdw','["cdw"]','incoming/cdw','package','known','Existing retailer package'),
(6,'costco','["costco"]','incoming/costco','package','known','Existing retailer package'),
(7,'crutchfield','["crutchfield"]','incoming/crutchfield','package','known','Existing retailer package'),
(8,'dell','["dell"]','incoming/dell','package','known','Existing retailer package'),
(9,'harborfreight','["harborfreight"]','incoming/harborfreight','package','known','Existing retailer package'),
(10,'kohls','["kohls"]','incoming/kohls','package','known','Existing retailer package'),
(11,'lenovo','["lenovo"]','incoming/lenovo','package','known','Existing retailer package'),
(12,'lowes','["lowes"]','incoming/lowes','package','known','Existing retailer package'),
(13,'microcenter','["microcenter"]','incoming/microcenter','package','known','Existing retailer package'),
(14,'newegg','["newegg"]','incoming/newegg','package','known','Existing retailer package'),
(15,'officedepot','["officedepot"]','incoming/officedepot','package','known','Existing retailer package'),
(16,'samsclub','["samsclub"]','incoming/samsclub','package','known','Existing retailer package'),
(17,'sears','["sears"]','incoming/sears','package','known','Existing retailer package'),
(18,'staples','["staples"]','incoming/staples','package','known','Existing retailer package'),
(19,'target','["target"]','incoming/target','package','known','Existing retailer package'),
(20,'bestbuy','["bestbuy","best_buy"]','scripts/brightdata-bestbuy-webunlocker-search-ingest.ts','worker','known','Existing production search worker'),
(21,'walmart','["walmart"]','scripts/test-walmart-brightdata-ingest.ts','test_harness','known','Visible test harness; never auto-certify'),
(22,NULL,'[]','','package','missing_identity','Expected 22nd scraper is not identifiable from current main; deliberately fail closed')
ON CONFLICT(expected_slot) DO UPDATE SET platform_code=EXCLUDED.platform_code,platform_code_candidates=EXCLUDED.platform_code_candidates,implementation_root=EXCLUDED.implementation_root,implementation_kind=EXCLUDED.implementation_kind,expectation_status=EXCLUDED.expectation_status,notes=EXCLUDED.notes;

ALTER TABLE retail.retail_search_adapters ADD COLUMN IF NOT EXISTS scraper_asset_id uuid REFERENCES retail.retail_scraper_assets(id) ON DELETE RESTRICT;
ALTER TABLE retail.retail_search_adapters ADD COLUMN IF NOT EXISTS scraper_contract_id uuid REFERENCES retail.retail_scraper_contracts(id) ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION retail.r1b_scraper_contract_is_current(p_adapter_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,retail AS $$
 SELECT COALESCE((SELECT a.certification_status='certified_dynamic_search' AND a.scraper_asset_id=s.id AND a.scraper_contract_id=c.id
  AND s.discovery_status='verified' AND s.verification_evidence_sha256 IS NOT NULL
  AND c.adapter_id=a.id AND c.scraper_asset_id=s.id AND c.certification_status='certified_for_r1'
  AND c.contract_sha256=retail.r1b_sha256_jsonb(c.contract_document) AND c.interface_evidence_sha256 IS NOT NULL
 FROM retail.retail_search_adapters a JOIN retail.retail_scraper_assets s ON s.id=a.scraper_asset_id
 JOIN retail.retail_scraper_contracts c ON c.id=a.scraper_contract_id WHERE a.id=p_adapter_id),false)
$$;

CREATE OR REPLACE FUNCTION retail.r1b_adapter_execution_ready(p_adapter_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,retail AS $$
 SELECT retail.r1b_adapter_is_certified_current(p_adapter_id)=true AND retail.r1b_scraper_contract_is_current(p_adapter_id)=true
$$;

CREATE OR REPLACE FUNCTION retail.r1b_scraper_integration_readiness()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,retail AS $$
 WITH x AS (SELECT count(*) FILTER(WHERE expectation_status='known') expected_known,count(*) FILTER(WHERE expectation_status='missing_identity') unidentified,22 expected_total FROM retail.r1b_expected_scraper_inventory),
 m AS (SELECT count(*) FILTER(WHERE inventory_status IN('discovered','verified')) inventoried,count(*) FILTER(WHERE inventory_status='verified') verified,count(*) FILTER(WHERE r1b_certification_status='certified_for_r1') certified_for_r1,count(*) FILTER(WHERE r1b_certification_status='test_only') test_only FROM retail.r1b_adapter_integration_matrix)
 SELECT jsonb_build_object('expected_total',x.expected_total,'expected_known',x.expected_known,'unidentified',x.unidentified,'inventoried',coalesce(m.inventoried,0),'verified',coalesce(m.verified,0),'certified_for_r1',coalesce(m.certified_for_r1,0),'test_only',coalesce(m.test_only,0),'all_known_inventoried',coalesce(m.inventoried,0)>=x.expected_known,'full_22_identified',x.unidentified=0) FROM x,m
$$;

CREATE OR REPLACE FUNCTION retail_audit.r1b_integration_log_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,retail_audit AS $$
DECLARE v_row jsonb;v_actor text;BEGIN v_row:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
v_actor:=coalesce(nullif(current_setting('app.actor_name',true),''),nullif(current_setting('app.actor_id',true),''),session_user);
INSERT INTO retail_audit.retail_change_log(schema_name,table_name,operation,row_pk,old_data,new_data,changed_by) VALUES(TG_TABLE_SCHEMA,TG_TABLE_NAME,TG_OP,coalesce(v_row->>'id',v_row->>'expected_slot',''),CASE WHEN TG_OP IN('UPDATE','DELETE') THEN to_jsonb(OLD) END,CASE WHEN TG_OP IN('INSERT','UPDATE') THEN to_jsonb(NEW) END,v_actor);RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;END $$;
DROP TRIGGER IF EXISTS trg_r1b_audit_scraper_assets ON retail.retail_scraper_assets;CREATE TRIGGER trg_r1b_audit_scraper_assets AFTER INSERT OR UPDATE OR DELETE ON retail.retail_scraper_assets FOR EACH ROW EXECUTE FUNCTION retail_audit.r1b_integration_log_change();
DROP TRIGGER IF EXISTS trg_r1b_audit_scraper_contracts ON retail.retail_scraper_contracts;CREATE TRIGGER trg_r1b_audit_scraper_contracts AFTER INSERT OR UPDATE OR DELETE ON retail.retail_scraper_contracts FOR EACH ROW EXECUTE FUNCTION retail_audit.r1b_integration_log_change();
DROP TRIGGER IF EXISTS trg_r1b_audit_adapter_matrix ON retail.r1b_adapter_integration_matrix;CREATE TRIGGER trg_r1b_audit_adapter_matrix AFTER INSERT OR UPDATE OR DELETE ON retail.r1b_adapter_integration_matrix FOR EACH ROW EXECUTE FUNCTION retail_audit.r1b_integration_log_change();
REVOKE ALL ON FUNCTION retail.r1b_scraper_contract_is_current(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION retail.r1b_adapter_execution_ready(uuid) FROM PUBLIC;
COMMIT;
