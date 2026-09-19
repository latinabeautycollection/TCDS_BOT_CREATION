BEGIN;

GRANT SELECT ON retail.r1e_effective_qualified_products
  TO retail_r1e_reader;
GRANT SELECT ON retail.r1e_pending_captures
  TO retail_r1e_reader;

COMMIT;
