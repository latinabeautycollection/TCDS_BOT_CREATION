BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM retail.r1a_schema_state
    WHERE singleton AND schema_version = '2.0.0'
  ) THEN
    RAISE EXCEPTION 'R1A schema 2.0.0 is required';
  END IF;

  IF to_regclass('retail.r1a_authorized_watchlist') IS NULL THEN
    RAISE EXCEPTION 'R1A authorized watchlist authority is missing';
  END IF;
END
$$;

-- Rank controls cohort admission. Movement among already-admitted products
-- does not change their execution identity.
CREATE OR REPLACE FUNCTION retail.r1a_stable_upstream_document(p_doc jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT p_doc #- '{candidate_authority,category_rank}'
$$;

-- Preserve an approved immutable snapshot hash when the only upstream change
-- is category rank. Any other drift returns the newly observed hash and fails
-- the existing effective-view equality check. Missing cohort membership still
-- returns NULL and therefore remains fail-closed.
CREATE OR REPLACE FUNCTION retail.r1a_current_upstream_hash(
  p_watchlist_id bigint
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, retail, arb
AS $$
  WITH current_authority AS (
    SELECT retail.r1a_current_upstream_document(p_watchlist_id) AS doc
    WHERE EXISTS (
      SELECT 1
      FROM retail.r1a_authorized_watchlist a
      WHERE a.watchlist_id = p_watchlist_id
    )
  )
  SELECT CASE
    WHEN current_authority.doc IS NULL THEN NULL
    ELSE coalesce(
      (
        SELECT r.upstream_snapshot_hash
        FROM retail.search_targets t
        JOIN retail.search_target_revisions r
          ON r.target_id = t.id
         AND r.revision_no = t.current_revision_no
         AND r.approval_status = 'approved'
        WHERE t.upstream_watchlist_id = p_watchlist_id
          AND retail.r1a_stable_upstream_document(r.upstream_snapshot) =
              retail.r1a_stable_upstream_document(current_authority.doc)
        ORDER BY t.id
        LIMIT 1
      ),
      retail.r1a_sha256_jsonb(current_authority.doc)
    )
  END
  FROM current_authority
$$;

DO $$
DECLARE
  unexpected_stale integer;
BEGIN
  SELECT count(*)
  INTO unexpected_stale
  FROM retail.search_targets t
  JOIN retail.search_target_revisions r
    ON r.target_id = t.id
   AND r.revision_no = t.current_revision_no
  JOIN retail.r1a_authorized_watchlist a
    ON a.watchlist_id = t.upstream_watchlist_id
  WHERE t.status = 'active'
    AND r.approval_status = 'approved'
    AND retail.r1a_stable_upstream_document(r.upstream_snapshot) IS DISTINCT FROM
        retail.r1a_stable_upstream_document(
          retail.r1a_current_upstream_document(t.upstream_watchlist_id)
        );

  IF unexpected_stale <> 0 THEN
    RAISE EXCEPTION
      'R1A rank-stability migration found % non-rank authority changes',
      unexpected_stale;
  END IF;
END
$$;

COMMIT;
