BEGIN;


DO $$
BEGIN
  IF to_regclass('retail.r1a_authorized_watchlist') IS NULL THEN
    RAISE EXCEPTION 'R1A authorized watchlist view is required';
  END IF;
END
$$;

WITH rejected AS (
  UPDATE retail.search_target_revisions r
  SET approval_status = 'rejected'
  FROM retail.search_targets t
  WHERE t.id = r.target_id
    AND r.approval_status = 'pending'
    AND r.search_policy->>'product_authority'
        = 'public.prong2_top500_items'
    AND NOT EXISTS (
      SELECT 1
      FROM retail.r1a_authorized_watchlist a
      WHERE a.watchlist_id = r.upstream_watchlist_id
    )
  RETURNING r.id
)
SELECT count(*) AS rejected_revisions
FROM rejected;

COMMIT;
