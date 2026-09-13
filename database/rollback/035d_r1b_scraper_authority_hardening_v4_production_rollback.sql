BEGIN;

-- Non-destructive R1B V4 scraper-authority rollback.
-- Preserve all inventory, contracts, hashes and certification evidence.
UPDATE retail.search_route_bindings
SET route_status='paused',updated_at=now()
WHERE route_status='approved';

UPDATE retail.retail_search_adapters
SET certification_status='suspended',
    suspended_reason='R1B V4 scraper-authority production rollback',
    updated_at=now()
WHERE certification_status='certified_dynamic_search';

UPDATE retail.retail_scraper_contracts
SET certification_status='blocked',
    status_reason='R1B V4 scraper-authority production rollback',
    updated_at=now()
WHERE certification_status='certified_for_r1';

COMMIT;
