-- TCDS 047b: read-only ZSL5 -> future ZSL6 acquisition-cost authority contract
BEGIN;
CREATE OR REPLACE VIEW zsl.zsl5_zsl6_acquisition_cost_authority_v14 AS
SELECT q.transaction_id,q.build_run_id,b.publication_id,q.evaluation_as_of,q.state_code,q.jurisdiction_codes,
       q.taxable_base_cents,q.checkout_tax_estimate_cents,q.estimated_legal_tax_burden_cents,q.potential_use_tax_cents,
       q.mandatory_government_fees_cents,q.total_government_acquisition_cost_cents,q.confidence_score,q.confidence_label,
       q.missingness_status,q.evidence_sha256,q.created_at
FROM zsl.zsl5_tax_quote_evidence_v14 q
JOIN zsl.zsl5_current_authority a ON a.build_run_id=q.build_run_id AND a.engine_version='zsl5-v1.4.0'
JOIN zsl.zsl5_national_publication_bindings_v14 b ON b.build_run_id=q.build_run_id
WHERE q.confidence_label='HIGH' AND q.missingness_status='PRESENT' AND zsl.zsl5_bindings_still_valid(q.build_run_id);

COMMENT ON VIEW zsl.zsl5_zsl6_acquisition_cost_authority_v14 IS
'ZSL5-owned read-only tax/government acquisition-cost authority contract for future ZSL6 consumption. ZSL6 may consume but must not recalculate or mutate tax authority.';
GRANT SELECT ON zsl.zsl5_zsl6_acquisition_cost_authority_v14 TO zsl5_reader;
COMMIT;
