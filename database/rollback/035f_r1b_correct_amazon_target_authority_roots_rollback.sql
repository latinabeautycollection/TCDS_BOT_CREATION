BEGIN;

DO $$
DECLARE
  restored_rows integer;
BEGIN
  UPDATE retail.r1b_expected_scraper_inventory AS inventory
  SET implementation_root = original.implementation_root
  FROM (
    VALUES
      ('amazon', 'incoming/amazon'),
      ('target', 'incoming/target')
  ) AS original(platform_code, implementation_root)
  WHERE inventory.platform_code = original.platform_code;

  SELECT count(*)
  INTO restored_rows
  FROM retail.r1b_expected_scraper_inventory AS inventory
  JOIN (
    VALUES
      ('amazon', 'incoming/amazon'),
      ('target', 'incoming/target')
  ) AS original(platform_code, implementation_root)
    ON original.platform_code = inventory.platform_code
   AND original.implementation_root = inventory.implementation_root;

  IF restored_rows <> 2 THEN
    RAISE EXCEPTION
      'Expected two restored scraper roots, found %',
      restored_rows;
  END IF;
END
$$;

COMMIT;
