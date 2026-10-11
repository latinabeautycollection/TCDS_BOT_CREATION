BEGIN;
INSERT INTO zsl.source_registry(source_key, source_name, source_class, authority_level, access_type, landing_url)
VALUES
  ('CENSUS_CBP', 'Census County Business Patterns', 'ECONOMICS_BUSINESS', 'FEDERAL', 'BULK_FILE', 'https://www.census.gov/programs-surveys/cbp/data/datasets.html'),
  ('CENSUS_ZBP', 'Census ZIP Code Business Patterns', 'ECONOMICS_BUSINESS', 'FEDERAL', 'BULK_FILE', 'https://www.census.gov/programs-surveys/cbp/data/datasets.html')
ON CONFLICT(source_key) DO NOTHING;
COMMIT;
