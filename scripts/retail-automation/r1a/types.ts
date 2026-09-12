export type PriorityTier = 'A_PLUS' | 'A' | 'B' | 'C' | 'D';

export interface ArbWatchlistRow {
  id: number;
  strategy_id: number | null;
  category_key: string;
  family_key: string;
  family_name: string;
  brand: string | null;
  model_family: string | null;
  keyword_fingerprint: string | null;
  overall_watch_score: number | null;
  predicted_buy_cost_usd: number | null;
  status: string;

  normalized_brand: string | null;
  normalized_product_type: string | null;
  normalized_model_family: string | null;
  normalized_model_token: string | null;
  normalized_generation: string | null;
  normalized_variant: string | null;
  normalized_storage: string | null;
  normalized_color: string | null;
  normalized_platform: string | null;
  canonical_product_key: string | null;

  identity_confidence: number | null;
  is_accessory: boolean | null;
  is_bundle: boolean | null;

  cohort_product_key: string;
  representative_candidate_id: string | number;
  category_rank: string | number;
  max_products_per_run: number;

  cohort_brand: string | null;
  cohort_model: string | null;
  cohort_mpn: string | null;
  cohort_ebay_mpn_seen: string | null;
  cohort_title: string;
  cohort_normalized_title: string | null;
  cohort_normalized_brand: string | null;
  cohort_normalized_product_type: string | null;
  cohort_normalized_model_family: string | null;
  cohort_normalized_model_token: string | null;
  cohort_normalized_generation: string | null;
  cohort_normalized_variant: string | null;
  cohort_normalized_storage: string | null;
  cohort_normalized_platform: string | null;
  cohort_condition_text: string | null;
  cohort_identity_confidence: number | null;
  cohort_best_match_score: number;
  cohort_match_class: string;
}
