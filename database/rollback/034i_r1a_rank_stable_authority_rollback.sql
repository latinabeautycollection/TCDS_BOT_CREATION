BEGIN;

CREATE OR REPLACE FUNCTION retail.r1a_current_upstream_hash(
  p_watchlist_id bigint
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, retail, arb
AS $$
  SELECT CASE
    WHEN EXISTS (
      SELECT 1
      FROM retail.r1a_authorized_watchlist a
      WHERE a.watchlist_id = p_watchlist_id
    )
    THEN retail.r1a_sha256_jsonb(
      retail.r1a_current_upstream_document(p_watchlist_id)
    )
    ELSE NULL
  END
$$;

DROP FUNCTION retail.r1a_stable_upstream_document(jsonb);

COMMIT;
