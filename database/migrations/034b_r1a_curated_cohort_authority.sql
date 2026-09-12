BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM retail.r1a_schema_state
    WHERE singleton AND schema_version = '2.0.0'
  ) THEN
    RAISE EXCEPTION 'R1A schema 2.0.0 is required';
  END IF;

  IF to_regclass('public.prong2_top500_items') IS NULL THEN
    RAISE EXCEPTION 'Curated prong2_top500_items authority is missing';
  END IF;
END
$$;

CREATE OR REPLACE VIEW retail.r1a_authorized_watchlist AS
WITH identity_candidates AS (
  SELECT
    p.product_key AS cohort_product_key,
    p.representative_candidate_id,
    w.id AS watchlist_id,
    w.category_key,
    w.overall_watch_score,
    w.identity_confidence,
    s.max_products_per_run,
    row_number() OVER (
      PARTITION BY p.product_key
      ORDER BY
        w.identity_confidence DESC NULLS LAST,
        w.overall_watch_score DESC NULLS LAST,
        w.id
    ) AS identity_rank
  FROM public.prong2_top500_items p
  JOIN arb.product_watchlist w
    ON w.canonical_product_key = p.product_key
   AND w.category_key = p.source_category_key
  JOIN arb.market_category_strategy s
    ON s.id = w.strategy_id
   AND s.category_key = w.category_key
   AND s.is_active = true
  WHERE p.product_key IS NOT NULL
    AND p.grain_quality = 'resolved_item'
    AND w.status = 'active'
    AND coalesce(w.is_accessory, false) = false
),
deduplicated AS (
  SELECT *
  FROM identity_candidates
  WHERE identity_rank = 1
),
ranked AS (
  SELECT *,
    row_number() OVER (
      PARTITION BY category_key
      ORDER BY
        overall_watch_score DESC NULLS LAST,
        identity_confidence DESC NULLS LAST,
        watchlist_id
    ) AS category_rank
  FROM deduplicated
)
SELECT *
FROM ranked
WHERE category_rank <= max_products_per_run;

COMMENT ON VIEW retail.r1a_authorized_watchlist IS
  'R1A product authority: curated top-500 intersection, resolved product grain, category alignment, deterministic identity selection, active strategy and per-category cap.';

INSERT INTO arb.category_whitelist(category_key, description, is_enabled)
SELECT DISTINCT
  category_key,
  'Authorized by R1A curated prong2 top-500 cohort policy',
  true
FROM retail.r1a_authorized_watchlist
ON CONFLICT (category_key) DO NOTHING;

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

COMMIT;
