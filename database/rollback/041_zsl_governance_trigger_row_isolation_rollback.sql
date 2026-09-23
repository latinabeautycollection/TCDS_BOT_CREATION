BEGIN;

CREATE OR REPLACE FUNCTION zsl.prevent_governance_content_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_TABLE_NAME='source_policies' AND (NEW.source_id,NEW.policy_version,NEW.policy_document,NEW.policy_sha256) IS DISTINCT FROM (OLD.source_id,OLD.policy_version,OLD.policy_document,OLD.policy_sha256) THEN RAISE EXCEPTION 'SOURCE_POLICY_CONTENT_IMMUTABLE';END IF;
  IF TG_TABLE_NAME='schema_contracts' AND (NEW.source_id,NEW.contract_version,NEW.contract_document,NEW.contract_sha256) IS DISTINCT FROM (OLD.source_id,OLD.contract_version,OLD.contract_document,OLD.contract_sha256) THEN RAISE EXCEPTION 'SCHEMA_CONTRACT_CONTENT_IMMUTABLE';END IF;
  IF TG_TABLE_NAME='certification_policies' AND (NEW.policy_version,NEW.policy_document,NEW.policy_sha256) IS DISTINCT FROM (OLD.policy_version,OLD.policy_document,OLD.policy_sha256) THEN RAISE EXCEPTION 'CERTIFICATION_POLICY_CONTENT_IMMUTABLE';END IF;
  RETURN NEW;
END
$function$;

COMMIT;
