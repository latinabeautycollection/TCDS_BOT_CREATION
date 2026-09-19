BEGIN;

REVOKE SELECT ON retail.r1e_effective_qualified_products
  FROM retail_r1e_reader;
REVOKE SELECT ON retail.r1e_pending_captures
  FROM retail_r1e_reader;

COMMIT;
