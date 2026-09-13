BEGIN;
UPDATE retail.r1b_adapter_integration_matrix SET r1b_certification_status='blocked',updated_at=now() WHERE r1b_certification_status IN('contract_verified','qa_passed','certified_for_r1');
UPDATE retail.retail_scraper_contracts SET certification_status='blocked' WHERE certification_status IN('contract_verified','qa_passed','certified_for_r1');
COMMIT;
