BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM retail.r1a_schema_state
    WHERE singleton
      AND schema_version = '2.0.0'
  ) THEN
    RAISE EXCEPTION 'R1A schema 2.0.0 is required';
  END IF;

  IF to_regclass('public.prong2_top500_items') IS NULL THEN
    RAISE EXCEPTION 'Curated prong2_top500_items authority is missing';
  END IF;
END
$$;

CREATE OR REPLACE VIEW retail.r1a_authorized_watchlist AS
WITH exact_candidates AS (
  SELECT
    p.product_key AS cohort_product_key,
    p.representative_candidate_id,
    w.id AS watchlist_id,
    w.category_key,
    w.overall_watch_score,
    w.identity_confidence,
    s.max_products_per_run,
    1::bigint AS identity_rank
  FROM public.prong2_top500_items p
  JOIN arb.candidates c
    ON c.id = p.representative_candidate_id
  JOIN arb.product_watchlist w
    ON w.id = c.matched_watchlist_id
   AND w.category_key = p.source_category_key
  JOIN arb.market_category_strategy s
    ON s.id = w.strategy_id
   AND s.category_key = w.category_key
   AND s.is_active = true
  WHERE p.product_key IS NOT NULL
    AND p.grain_quality = 'resolved_item'
    AND c.matched_watchlist_id IS NOT NULL
    AND c.best_match_score >= 0.70
    AND c.best_match_reason_json #>> '{summary,matchClass}' = 'exact_match'
    AND coalesce(p.is_accessory, false) = false
    AND coalesce(c.is_accessory, false) = false
    AND coalesce(c.is_bundle, false) = false
    AND w.status = 'active'
    AND coalesce(w.is_accessory, false) = false
    AND NOT (
      coalesce(
        c.best_match_reason_json #> '{diagnostics,rejectionReasons}',
        '[]'::jsonb
      ) ?| ARRAY[
        'model_family_mismatch',
        'model_token_mismatch',
        'accessory_mismatch',
        'bundle_mismatch',
        'generation_mismatch',
        'storage_mismatch',
        'variant_mismatch',
        'platform_mismatch'
      ]
    )
),
ranked AS (
  SELECT
    exact_candidates.*,
    row_number() OVER (
      PARTITION BY category_key
      ORDER BY
        overall_watch_score DESC NULLS LAST,
        identity_confidence DESC NULLS LAST,
        watchlist_id
    ) AS category_rank
  FROM exact_candidates
)
SELECT *
FROM ranked
WHERE category_rank <= max_products_per_run;

COMMENT ON VIEW retail.r1a_authorized_watchlist IS
  'R1A authority: curated top-500 candidates with promoted exact watchlist matches, strict mismatch rejection, active strategy, and per-category cap.';

UPDATE arb.category_whitelist
SET is_enabled = EXISTS (
      SELECT 1
      FROM retail.r1a_authorized_watchlist a
      WHERE a.category_key = arb.category_whitelist.category_key
    ),
    description =
      'Authorized by R1A curated exact-match cohort policy'
WHERE description =
  'Authorized by R1A curated prong2 top-500 cohort policy';

INSERT INTO arb.category_whitelist (
  category_key,
  description,
  is_enabled
)
SELECT DISTINCT
  category_key,
  'Authorized by R1A curated exact-match cohort policy',
  true
FROM retail.r1a_authorized_watchlist
ON CONFLICT (category_key) DO UPDATE
SET is_enabled = true,
    description = EXCLUDED.description;

COMMIT;
