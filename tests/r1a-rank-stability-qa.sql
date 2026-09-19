BEGIN;

DO $$
DECLARE
  base jsonb := '{"candidate_authority":{"product_key":"p1","category_rank":1},"watchlist":{"id":1}}';
  moved jsonb := '{"candidate_authority":{"product_key":"p1","category_rank":9},"watchlist":{"id":1}}';
  changed jsonb := '{"candidate_authority":{"product_key":"p2","category_rank":1},"watchlist":{"id":1}}';
BEGIN
  IF retail.r1a_stable_upstream_document(base) IS DISTINCT FROM
     retail.r1a_stable_upstream_document(moved) THEN
    RAISE EXCEPTION 'rank-only movement changed stable authority';
  END IF;

  IF retail.r1a_stable_upstream_document(base) IS NOT DISTINCT FROM
     retail.r1a_stable_upstream_document(changed) THEN
    RAISE EXCEPTION 'candidate identity change was ignored';
  END IF;
END
$$;

SELECT
  count(*) AS authorized_targets,
  count(*) FILTER (
    WHERE r.upstream_snapshot_hash =
      retail.r1a_current_upstream_hash(t.upstream_watchlist_id)
  ) AS current_authorized_targets
FROM retail.search_targets t
JOIN retail.search_target_revisions r
  ON r.target_id = t.id AND r.revision_no = t.current_revision_no
JOIN retail.r1a_authorized_watchlist a
  ON a.watchlist_id = t.upstream_watchlist_id
WHERE t.status = 'active' AND r.approval_status = 'approved';

ROLLBACK;
