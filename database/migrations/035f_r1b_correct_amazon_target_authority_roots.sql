BEGIN;

DO $$
DECLARE
  correct_rows integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM retail.r1b_scraper_authority_state
    WHERE singleton = true
      AND hardening_version = '4.0.0'
  ) THEN
    RAISE EXCEPTION 'R1B scraper authority 4.0.0 is required';
  END IF;

  UPDATE retail.r1b_expected_scraper_inventory AS inventory
  SET implementation_root = desired.implementation_root
  FROM (
    VALUES
      (
        'amazon',
        'incoming/amazon/tcds-amazon-ingest'
      ),
      (
        'target',
        'incoming/target/tcds-target-brightdata-ingest'
      )
  ) AS desired(platform_code, implementation_root)
  WHERE inventory.platform_code = desired.platform_code;

  SELECT count(*)
  INTO correct_rows
  FROM retail.r1b_expected_scraper_inventory AS inventory
  JOIN (
    VALUES
      (
        'amazon',
        'incoming/amazon/tcds-amazon-ingest'
      ),
      (
        'target',
        'incoming/target/tcds-target-brightdata-ingest'
      )
  ) AS desired(platform_code, implementation_root)
    ON desired.platform_code = inventory.platform_code
   AND desired.implementation_root = inventory.implementation_root;

  IF correct_rows <> 2 THEN
    RAISE EXCEPTION
      'Expected two corrected scraper roots, found %',
      correct_rows;
  END IF;
END
$$;

COMMIT;
