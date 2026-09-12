BEGIN;


DO $$
BEGIN
  IF to_regclass('retail.r1a_authorized_watchlist') IS NULL THEN
    RAISE EXCEPTION 'R1A authorized watchlist view is required';
  END IF;
END
$$;

WITH rejected AS (
  UPDATE retail.search_target_revisions older
  SET approval_status = 'rejected'
  WHERE older.approval_status = 'pending'
    AND EXISTS (
      SELECT 1
      FROM retail.search_target_revisions newer
      WHERE newer.target_id = older.target_id
        AND newer.approval_status = 'pending'
        AND newer.revision_no > older.revision_no
    )
  RETURNING older.id
)
SELECT count(*) AS older_revisions_rejected
FROM rejected;

WITH retired AS (
  UPDATE retail.search_targets t
  SET status = 'retired',
      retired_at = coalesce(t.retired_at, now())
  WHERE t.status <> 'retired'
    AND NOT EXISTS (
      SELECT 1
      FROM retail.r1a_authorized_watchlist a
      WHERE a.watchlist_id = t.upstream_watchlist_id
    )
  RETURNING t.id
)
SELECT count(*) AS unsafe_targets_retired
FROM retired;

COMMIT;
