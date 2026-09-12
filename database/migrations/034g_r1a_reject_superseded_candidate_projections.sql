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
        AND newer.search_policy->>'authority_policy'
            = 'r1a-curated-exact-v1'
    )
  RETURNING older.id
)
SELECT count(*) AS superseded_pending_rejected
FROM rejected;

COMMIT;
