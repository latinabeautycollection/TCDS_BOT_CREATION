BEGIN;

-- R1B V3 NON-DESTRUCTIVE PRODUCTION ROLLBACK
-- Preserve all route, adapter, location, audit and certification evidence.

UPDATE retail.search_route_bindings
SET route_status='paused',
    updated_at=now()
WHERE route_status='approved';

UPDATE retail.retail_search_adapters
SET certification_status='suspended',
    suspended_reason=COALESCE(suspended_reason,'R1B V3 production rollback'),
    updated_at=now()
WHERE certification_status='certified_dynamic_search';

UPDATE retail.r1b_schema_state
SET ownership_doctrine=ownership_doctrine || ' [ROLLBACK_SUSPENDED]'
WHERE singleton=true;

COMMIT;
