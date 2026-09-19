BEGIN;

UPDATE retail.platform_collection_sources
SET is_active = false,
    is_approved = false,
    updated_at = now()
WHERE platform_id = 'c0515b32-89e1-4ac4-b767-ed50df8cb433'
  AND source_code = 'target_keyword_national';

UPDATE retail.platform_collection_configs
SET is_active = false,
    updated_at = now()
WHERE platform_id = 'c0515b32-89e1-4ac4-b767-ed50df8cb433'
  AND config_name = 'Target R1B governed keyword discovery v1';

COMMIT;
