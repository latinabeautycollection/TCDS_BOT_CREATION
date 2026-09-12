BEGIN;

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

CREATE OR REPLACE VIEW retail.effective_search_targets AS
SELECT
  t.id AS target_id,
  t.target_code,
  t.upstream_watchlist_id,
  w.strategy_id AS upstream_strategy_id,
  t.current_revision_no,
  r.id AS revision_id,
  r.revision_hash,
  r.upstream_snapshot_hash,
  r.category_key,
  r.family_key,
  r.family_name,
  r.canonical_product_key,
  r.brand,
  r.model_family,
  r.normalized_product_type,
  r.normalized_model_token,
  r.normalized_generation,
  r.normalized_variant,
  r.normalized_storage,
  r.normalized_platform,
  r.upstream_identity_confidence,
  r.keyword_fingerprint,
  r.include_terms,
  r.exclude_terms,
  r.allowed_conditions,
  r.desired_source_types,
  r.desired_discount_signals,
  r.discovery_price_ceiling_usd,
  r.discovery_result_limit,
  r.priority_tier,
  r.search_policy,
  r.source_process_run_id,
  r.source_correlation_id
FROM retail.search_targets t
JOIN retail.search_target_revisions r
  ON r.target_id = t.id
 AND r.revision_no = t.current_revision_no
 AND r.approval_status = 'approved'
JOIN retail.r1a_authorized_watchlist a
  ON a.watchlist_id = t.upstream_watchlist_id
JOIN arb.product_watchlist w
  ON w.id = t.upstream_watchlist_id
JOIN arb.category_whitelist cw
  ON cw.category_key = w.category_key
JOIN arb.market_category_strategy ms
  ON ms.id = w.strategy_id
WHERE t.status = 'active'
  AND w.status = 'active'
  AND coalesce(w.is_accessory, false) = false
  AND cw.is_enabled = true
  AND ms.is_active = true
  AND r.upstream_watchlist_id = w.id
  AND r.upstream_strategy_id IS NOT DISTINCT FROM w.strategy_id
  AND r.category_key = w.category_key
  AND r.family_key = a.cohort_product_key
  AND r.canonical_product_key = a.cohort_product_key
  AND r.upstream_snapshot_hash =
      retail.r1a_current_upstream_hash(t.upstream_watchlist_id)
  AND retail.r1a_sha256_jsonb(
        retail.r1a_revision_business_document(r)
      ) = r.revision_hash;

COMMENT ON VIEW retail.effective_search_targets IS
  'R1A sole executable authority using approved, current, curated exact-match candidate identity. R1B/R1C/R1D must consume only this view.';

COMMIT;
