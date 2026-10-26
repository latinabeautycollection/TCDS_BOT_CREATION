-- TCDS 047a: final-freeze database/data-type/temporal contract hardening
BEGIN;
DO $$ BEGIN
 IF to_regclass('zsl.zsl5_family_facts_v14') IS NULL OR to_regclass('zsl.zsl5_tax_quote_evidence_v14') IS NULL THEN RAISE EXCEPTION 'ZSL5_V14_RUNTIME_REQUIRED'; END IF;
 IF to_regclass('zsl_tax_acq.canonical_records') IS NULL THEN RAISE EXCEPTION 'ZSL1_TAX_ACQUISITION_REQUIRED'; END IF;
END $$;

ALTER TABLE zsl.zsl5_family_facts_v14
  ADD CONSTRAINT zsl5_v14_state_code_format CHECK(btrim(state_code) ~ '^[A-Z]{2}$') NOT VALID;
ALTER TABLE zsl.zsl5_family_facts_v14 VALIDATE CONSTRAINT zsl5_v14_state_code_format;
ALTER TABLE zsl.zsl5_family_facts_v14
  ADD CONSTRAINT zsl5_v14_effective_interval_half_open CHECK(effective_to IS NULL OR effective_from IS NULL OR effective_to>effective_from) NOT VALID;
ALTER TABLE zsl.zsl5_family_facts_v14 VALIDATE CONSTRAINT zsl5_v14_effective_interval_half_open;
ALTER TABLE zsl.zsl5_applicability_assertions_v14
  ADD CONSTRAINT zsl5_v14_assert_state_code_format CHECK(btrim(state_code) ~ '^[A-Z]{2}$') NOT VALID;
ALTER TABLE zsl.zsl5_applicability_assertions_v14 VALIDATE CONSTRAINT zsl5_v14_assert_state_code_format;
ALTER TABLE zsl.zsl5_tax_quote_evidence_v14
  ADD CONSTRAINT zsl5_v14_quote_state_code_format CHECK(btrim(state_code) ~ '^[A-Z]{2}$') NOT VALID;
ALTER TABLE zsl.zsl5_tax_quote_evidence_v14 VALIDATE CONSTRAINT zsl5_v14_quote_state_code_format;
ALTER TABLE zsl.zsl5_quote_transactions_v14
  ADD CONSTRAINT zsl5_v14_purchase_channel_check CHECK(purchase_channel IN('PHYSICAL_PICKUP','DELIVERY','SHIP_TO_STORE','MARKETPLACE')) NOT VALID;
ALTER TABLE zsl.zsl5_quote_transactions_v14 VALIDATE CONSTRAINT zsl5_v14_purchase_channel_check;

CREATE INDEX IF NOT EXISTS ix_zsl5_v14_fact_product ON zsl.zsl5_family_facts_v14(build_run_id,family,state_code,tax_product_class,tax_product_subclass,priority);
CREATE INDEX IF NOT EXISTS ix_zsl5_v14_fact_effective ON zsl.zsl5_family_facts_v14(build_run_id,state_code,family,effective_from,effective_to,priority);
CREATE INDEX IF NOT EXISTS ix_zsl5_v14_quote_build_eval ON zsl.zsl5_tax_quote_evidence_v14(build_run_id,evaluation_as_of,state_code);

CREATE OR REPLACE VIEW zsl.zsl5_v14_payload_contract_violations AS
SELECT fact_id,build_run_id,family,state_code,'MISSING_OR_INVALID_CANONICAL_PAYLOAD'::text violation
FROM zsl.zsl5_family_facts_v14 f
WHERE CASE family
 WHEN 'TAX_REGIME' THEN NOT (value_document ? 'regime_code' AND value_document ? 'general_sales_tax_applies')
 WHEN 'STATE_RATE' THEN NOT (value_document ? 'jurisdiction_code' AND value_document ? 'component_type' AND value_document ? 'rate' AND value_document ? 'rate_semantics')
 WHEN 'LOCAL_RATE' THEN NOT (value_document ? 'jurisdiction_code' AND value_document ? 'component_type' AND value_document ? 'rate' AND value_document ? 'rate_semantics')
 WHEN 'PRODUCT_TAXABILITY' THEN NOT (value_document ? 'tax_product_class' AND value_document ? 'purchase_channels' AND value_document ? 'taxable_fraction')
 WHEN 'TAXABLE_BASE_RULE' THEN NOT (value_document ? 'component_type' AND value_document ? 'treatment')
 WHEN 'TAX_HOLIDAY' THEN NOT (value_document ? 'holiday_code' AND value_document ? 'start_at' AND value_document ? 'end_at' AND value_document ? 'treatment')
 WHEN 'SOURCING_RULE' THEN NOT (value_document ? 'purchase_channel' AND value_document ? 'sourcing_basis')
 WHEN 'SELLER_COLLECTION_RULE' THEN NOT (value_document ? 'seller_class' AND value_document ? 'collection_requirement')
 WHEN 'MARKETPLACE_RULE' THEN NOT (value_document ? 'facilitator_collection_required')
 WHEN 'ROUNDING_RULE' THEN NOT (value_document ? 'rounding_mode' AND value_document ? 'precision' AND value_document ? 'round_at_line')
 WHEN 'MANDATORY_TRANSACTION_FEE' THEN NOT (value_document ? 'fee_code' AND value_document ? 'calculation_method')
 ELSE false END;
COMMIT;
