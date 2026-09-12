BEGIN;

CREATE OR REPLACE VIEW retail.r1a_authorized_watchlist AS
WITH exact_candidates_raw AS (
  SELECT
    p.product_key AS cohort_product_key,
    p.representative_candidate_id,
    w.id AS watchlist_id,
    w.category_key,
    w.overall_watch_score,
    w.identity_confidence,
    s.max_products_per_run,
    row_number() OVER (
      PARTITION BY w.id
      ORDER BY
        c.best_match_score DESC NULLS LAST,
        p.identity_confidence DESC NULLS LAST,
        p.representative_candidate_id
    ) AS identity_rank
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
deduplicated AS (
  SELECT *
  FROM exact_candidates_raw
  WHERE identity_rank = 1
),
ranked AS (
  SELECT
    deduplicated.*,
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
  'R1A exact candidate authority with one curated candidate per watchlist identity, active strategy, mismatch rejection, and category cap.';

CREATE OR REPLACE FUNCTION retail.r1a_current_upstream_document(
  p_watchlist_id bigint
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, retail, arb
AS $$
  SELECT jsonb_build_object(
    'authority_policy', 'r1a-curated-exact-v1',
    'watchlist', jsonb_build_object(
      'id', w.id,
      'strategy_id', w.strategy_id,
      'category_key', w.category_key,
      'family_key', w.family_key,
      'family_name', w.family_name,
      'brand', w.brand,
      'model_family', w.model_family,
      'keyword_fingerprint', w.keyword_fingerprint,
      'overall_watch_score', w.overall_watch_score,
      'predicted_buy_cost_usd', w.predicted_buy_cost_usd,
      'status', w.status,
      'normalized_brand', w.normalized_brand,
      'normalized_product_type', w.normalized_product_type,
      'normalized_model_family', w.normalized_model_family,
      'normalized_model_token', w.normalized_model_token,
      'normalized_generation', w.normalized_generation,
      'normalized_variant', w.normalized_variant,
      'normalized_storage', w.normalized_storage,
      'normalized_color', w.normalized_color,
      'normalized_platform', w.normalized_platform,
      'canonical_product_key', w.canonical_product_key,
      'identity_confidence', w.identity_confidence,
      'is_accessory', w.is_accessory,
      'is_bundle', w.is_bundle
    ),
    'candidate_authority', jsonb_build_object(
      'product_key', p.product_key,
      'representative_candidate_id', p.representative_candidate_id,
      'brand', p.brand,
      'model', p.model,
      'mpn', p.mpn,
      'ebay_mpn_seen', p.ebay_mpn_seen,
      'title', p.title,
      'normalized_title', p.normalized_title,
      'normalized_brand', p.normalized_brand,
      'normalized_model_family', p.normalized_model_family,
      'normalized_model_token', p.normalized_model_token,
      'normalized_generation', p.normalized_generation,
      'normalized_variant', p.normalized_variant,
      'normalized_storage', p.normalized_storage,
      'normalized_platform', p.normalized_platform,
      'condition_text', p.condition_text,
      'propertyroom_price_usd', p.propertyroom_price_usd,
      'ebay_median_price_usd', p.ebay_median_price_usd,
      'matched_watchlist_id', c.matched_watchlist_id,
      'best_match_score', c.best_match_score,
      'match_class',
        c.best_match_reason_json #>> '{summary,matchClass}',
      'match_evidence', c.best_match_reason_json,
      'category_rank', a.category_rank,
      'category_limit', a.max_products_per_run
    ),
    'strategy', jsonb_build_object(
      'id', ms.id,
      'category_key', ms.category_key,
      'is_active', ms.is_active,
      'metric_name', ms.metric_name,
      'max_products_per_run', ms.max_products_per_run,
      'min_price_usd', ms.min_price_usd,
      'max_price_usd', ms.max_price_usd,
      'min_demand_score', ms.min_demand_score,
      'min_predicted_profit_usd', ms.min_predicted_profit_usd,
      'min_margin_pct', ms.min_margin_pct,
      'include_keywords', to_jsonb(ms.include_keywords),
      'exclude_keywords', to_jsonb(ms.exclude_keywords)
    ),
    'category_authority', jsonb_build_object(
      'id', cw.id,
      'category_key', cw.category_key,
      'is_enabled', cw.is_enabled
    )
  )
  FROM retail.r1a_authorized_watchlist a
  JOIN public.prong2_top500_items p
    ON p.representative_candidate_id = a.representative_candidate_id
  JOIN arb.candidates c
    ON c.id = a.representative_candidate_id
  JOIN arb.product_watchlist w
    ON w.id = a.watchlist_id
  JOIN arb.market_category_strategy ms
    ON ms.id = w.strategy_id
  JOIN arb.category_whitelist cw
    ON cw.category_key = w.category_key
  WHERE a.watchlist_id = p_watchlist_id
$$;

CREATE OR REPLACE FUNCTION retail.r1a_prepare_revision()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, retail, arb
AS $$
DECLARE
  v_target_watchlist bigint;
  v_doc jsonb;
BEGIN
  SELECT upstream_watchlist_id
  INTO v_target_watchlist
  FROM retail.search_targets
  WHERE id = NEW.target_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1A revision target % does not exist', NEW.target_id;
  END IF;

  IF NEW.upstream_watchlist_id IS DISTINCT FROM v_target_watchlist THEN
    RAISE EXCEPTION 'R1A revision watchlist does not match target watchlist';
  END IF;

  v_doc := retail.r1a_current_upstream_document(
    NEW.upstream_watchlist_id
  );

  IF v_doc IS NULL THEN
    RAISE EXCEPTION
      'R1A revision blocked: exact candidate authority missing for watchlist %',
      NEW.upstream_watchlist_id;
  END IF;

  NEW.upstream_snapshot := v_doc;
  NEW.upstream_snapshot_hash :=
    retail.r1a_sha256_jsonb(v_doc);

  IF NEW.upstream_strategy_id IS DISTINCT FROM
       nullif(v_doc #>> '{watchlist,strategy_id}', '')::bigint THEN
    RAISE EXCEPTION 'R1A revision blocked: strategy drift';
  END IF;

  IF NEW.category_key IS DISTINCT FROM
       v_doc #>> '{watchlist,category_key}' THEN
    RAISE EXCEPTION 'R1A revision blocked: category drift';
  END IF;

  IF NEW.family_key IS DISTINCT FROM
       v_doc #>> '{candidate_authority,product_key}' THEN
    RAISE EXCEPTION 'R1A revision blocked: candidate identity drift';
  END IF;

  IF NEW.canonical_product_key IS DISTINCT FROM
       v_doc #>> '{candidate_authority,product_key}' THEN
    RAISE EXCEPTION 'R1A revision blocked: canonical identity drift';
  END IF;

  NEW.revision_hash :=
    retail.r1a_sha256_jsonb(
      retail.r1a_revision_business_document(NEW)
    );

  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION retail.r1a_revision_is_current(
  p_target_id uuid,
  p_revision_no integer
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, retail, arb
AS $$
  SELECT coalesce((
    SELECT
      t.upstream_watchlist_id = r.upstream_watchlist_id
      AND r.approval_status = 'approved'
      AND w.status = 'active'
      AND coalesce(w.is_accessory, false) = false
      AND cw.is_enabled = true
      AND r.upstream_strategy_id IS NOT DISTINCT FROM w.strategy_id
      AND r.category_key = w.category_key
      AND r.family_key = a.cohort_product_key
      AND r.canonical_product_key = a.cohort_product_key
      AND r.upstream_snapshot_hash =
          retail.r1a_current_upstream_hash(t.upstream_watchlist_id)
      AND ms.is_active = true
    FROM retail.search_targets t
    JOIN retail.search_target_revisions r
      ON r.target_id = t.id
     AND r.revision_no = p_revision_no
    JOIN retail.r1a_authorized_watchlist a
      ON a.watchlist_id = t.upstream_watchlist_id
    JOIN arb.product_watchlist w
      ON w.id = t.upstream_watchlist_id
    JOIN arb.category_whitelist cw
      ON cw.category_key = w.category_key
    JOIN arb.market_category_strategy ms
      ON ms.id = w.strategy_id
    WHERE t.id = p_target_id
  ), false)
$$;

COMMIT;
