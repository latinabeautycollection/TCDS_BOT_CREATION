BEGIN;

UPDATE retail.platform_collection_sources
SET
  is_active = false,
  is_approved = false,
  updated_at = now()
WHERE source_code = 'best_buy_targeted_sale_national'
  AND platform_id = (
    SELECT id
    FROM retail.retail_platforms
    WHERE platform_code = 'best_buy'
  );

UPDATE retail.platform_collection_configs
SET
  is_active = false,
  updated_at = now()
WHERE config_name = 'Best Buy R1B governed targeted search v1'
  AND platform_id = (
    SELECT id
    FROM retail.retail_platforms
    WHERE platform_code = 'best_buy'
  );

COMMIT;
