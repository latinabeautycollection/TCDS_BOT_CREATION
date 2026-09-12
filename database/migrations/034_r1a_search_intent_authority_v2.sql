BEGIN;

CREATE SCHEMA IF NOT EXISTS retail;
CREATE SCHEMA IF NOT EXISTS retail_audit;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================================
-- TCDS RETAIL R1A — SEARCH INTENT AUTHORITY
-- GREEN TIER 1 HARDENED V2 FINAL
--
-- R1A owns WHAT TCDS is authorized to search for.
-- R1A does NOT own final profitability, capital allocation, purchase authority,
-- checkout authority, retailer/source/location routing, or Bright Data budget.
-- ============================================================================

-- ---------- PRE-FLIGHT / FAIL-CLOSED MIGRATION GUARD -------------------------
DO $$
DECLARE
  v_version text;
BEGIN
  IF to_regclass('retail.r1a_schema_state') IS NULL THEN
    IF to_regclass('retail.search_targets') IS NOT NULL
       OR to_regclass('retail.search_target_revisions') IS NOT NULL
       OR to_regclass('retail.effective_search_targets') IS NOT NULL THEN
      RAISE EXCEPTION
        'R1A V2 preflight failed: prior R1A objects exist without a V2 schema marker. Do not overwrite or silently upgrade. Review/rollback the prior R1A package first.';
    END IF;
  ELSE
    SELECT schema_version INTO v_version
    FROM retail.r1a_schema_state
    WHERE singleton = true;

    IF v_version IS DISTINCT FROM '2.0.0' THEN
      RAISE EXCEPTION
        'R1A V2 preflight failed: existing schema version % is not 2.0.0', v_version;
    END IF;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS retail.r1a_schema_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton = true),
  schema_version text NOT NULL,
  ownership_doctrine text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now(),
  installed_by text NOT NULL DEFAULT session_user
);

INSERT INTO retail.r1a_schema_state(singleton, schema_version, ownership_doctrine)
VALUES (
  true,
  '2.0.0',
  'R1A owns search intent only; arb owns market/profit/capital authority; R1B+ own retailer/source/location routing.'
)
ON CONFLICT (singleton) DO NOTHING;

-- Register R1A provenance in the existing ARB process framework.
INSERT INTO arb.process_registry(
  process_name, phase_no, process_group, description, owner_team, active_flag
)
VALUES (
  'RETAIL_R1A_TARGET_SYNC',
  2,
  'RETAIL_AUTOMATION',
  'Projects approved ARB product-watchlist intelligence into governed R1A retail search intent.',
  'TCDS Retail Automation',
  true
)
ON CONFLICT (process_name) DO NOTHING;

-- ---------- CORE TARGET ------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.search_targets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_code text NOT NULL UNIQUE CHECK (target_code ~ '^[A-Z0-9_:-]+$'),
  upstream_watchlist_id bigint NOT NULL
    REFERENCES arb.product_watchlist(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','active','paused','retired')),
  current_revision_no integer NOT NULL DEFAULT 0
    CHECK (current_revision_no >= 0),

  created_by text NOT NULL,
  approved_by text,
  approved_at timestamptz,
  activated_at timestamptz,
  paused_at timestamptz,
  retired_at timestamptz,

  last_sync_process_run_id uuid REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  last_sync_correlation_id text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE (upstream_watchlist_id)
);

-- ---------- IMMUTABLE BUSINESS REVISIONS ------------------------------------
CREATE TABLE IF NOT EXISTS retail.search_target_revisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_id uuid NOT NULL
    REFERENCES retail.search_targets(id) ON DELETE RESTRICT,
  revision_no integer NOT NULL CHECK (revision_no > 0),

  upstream_watchlist_id bigint NOT NULL
    REFERENCES arb.product_watchlist(id) ON DELETE RESTRICT,
  upstream_strategy_id bigint
    REFERENCES arb.market_category_strategy(id) ON DELETE RESTRICT,

  category_key text NOT NULL,
  family_key text NOT NULL,
  family_name text NOT NULL,
  canonical_product_key text,

  brand text,
  model_family text,
  normalized_product_type text,
  normalized_model_token text,
  normalized_generation text,
  normalized_variant text,
  normalized_storage text,
  normalized_platform text,
  upstream_identity_confidence numeric,

  keyword_fingerprint text,
  include_terms jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(include_terms)='array'),
  exclude_terms jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(exclude_terms)='array'),

  -- Product condition is separate from merchandising/discount/source signals.
  allowed_conditions jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(allowed_conditions)='array'),
  desired_source_types jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(desired_source_types)='array'),
  desired_discount_signals jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(desired_discount_signals)='array'),

  -- Discovery optimization only. This is NEVER purchase/checkout authority.
  discovery_price_ceiling_usd numeric(12,2)
    CHECK (discovery_price_ceiling_usd IS NULL OR discovery_price_ceiling_usd > 0),
  discovery_result_limit integer NOT NULL DEFAULT 100
    CHECK (discovery_result_limit BETWEEN 1 AND 5000),
  priority_tier text NOT NULL DEFAULT 'B'
    CHECK (priority_tier IN ('A_PLUS','A','B','C','D')),
  search_policy jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(search_policy)='object'),

  -- DB-generated upstream and revision evidence.
  upstream_snapshot jsonb NOT NULL
    CHECK (jsonb_typeof(upstream_snapshot)='object'),
  upstream_snapshot_hash text NOT NULL
    CHECK (upstream_snapshot_hash ~ '^[0-9a-f]{64}$'),
  revision_hash text NOT NULL UNIQUE
    CHECK (revision_hash ~ '^[0-9a-f]{64}$'),

  approval_status text NOT NULL DEFAULT 'pending'
    CHECK (approval_status IN ('pending','approved','rejected','superseded')),
  approved_by text,
  approved_at timestamptz,

  source_process_run_id uuid NOT NULL
    REFERENCES arb.process_runs(run_id) ON DELETE RESTRICT,
  source_correlation_id text,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE(target_id, revision_no)
);

CREATE INDEX IF NOT EXISTS idx_r1a_targets_status
  ON retail.search_targets(status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_r1a_revisions_target
  ON retail.search_target_revisions(target_id, revision_no DESC);
CREATE INDEX IF NOT EXISTS idx_r1a_revisions_upstream
  ON retail.search_target_revisions(upstream_watchlist_id, upstream_strategy_id);
CREATE INDEX IF NOT EXISTS idx_r1a_revisions_approval
  ON retail.search_target_revisions(target_id, approval_status, revision_no DESC);

-- ---------- DATABASE CANONICAL HASH AUTHORITY -------------------------------
CREATE OR REPLACE FUNCTION retail.r1a_sha256_jsonb(p_doc jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT encode(digest(convert_to(p_doc::text, 'UTF8'), 'sha256'), 'hex')
$$;

-- The upstream document contains every ARB field that changes R1A execution
-- intent. PostgreSQL owns this representation so creation and validation use
-- the exact same canonical jsonb serialization.
CREATE OR REPLACE FUNCTION retail.r1a_current_upstream_document(p_watchlist_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, retail, arb
AS $$
  SELECT jsonb_build_object(
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
    'strategy', CASE WHEN ms.id IS NULL THEN NULL ELSE jsonb_build_object(
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
    ) END,
    'category_authority', CASE WHEN cw.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', cw.id,
      'category_key', cw.category_key,
      'is_enabled', cw.is_enabled
    ) END
  )
  FROM arb.product_watchlist w
  LEFT JOIN arb.market_category_strategy ms ON ms.id = w.strategy_id
  LEFT JOIN arb.category_whitelist cw ON cw.category_key = w.category_key
  WHERE w.id = p_watchlist_id
$$;

CREATE OR REPLACE FUNCTION retail.r1a_current_upstream_hash(p_watchlist_id bigint)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, retail, arb
AS $$
  SELECT retail.r1a_sha256_jsonb(retail.r1a_current_upstream_document(p_watchlist_id))
$$;

CREATE OR REPLACE FUNCTION retail.r1a_revision_business_document(
  p_row retail.search_target_revisions
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'target_id', p_row.target_id,
    'revision_no', p_row.revision_no,
    'upstream_watchlist_id', p_row.upstream_watchlist_id,
    'upstream_strategy_id', p_row.upstream_strategy_id,
    'category_key', p_row.category_key,
    'family_key', p_row.family_key,
    'family_name', p_row.family_name,
    'canonical_product_key', p_row.canonical_product_key,
    'brand', p_row.brand,
    'model_family', p_row.model_family,
    'normalized_product_type', p_row.normalized_product_type,
    'normalized_model_token', p_row.normalized_model_token,
    'normalized_generation', p_row.normalized_generation,
    'normalized_variant', p_row.normalized_variant,
    'normalized_storage', p_row.normalized_storage,
    'normalized_platform', p_row.normalized_platform,
    'upstream_identity_confidence', p_row.upstream_identity_confidence,
    'keyword_fingerprint', p_row.keyword_fingerprint,
    'include_terms', p_row.include_terms,
    'exclude_terms', p_row.exclude_terms,
    'allowed_conditions', p_row.allowed_conditions,
    'desired_source_types', p_row.desired_source_types,
    'desired_discount_signals', p_row.desired_discount_signals,
    'discovery_price_ceiling_usd', p_row.discovery_price_ceiling_usd,
    'discovery_result_limit', p_row.discovery_result_limit,
    'priority_tier', p_row.priority_tier,
    'search_policy', p_row.search_policy,
    'upstream_snapshot_hash', p_row.upstream_snapshot_hash
  )
$$;

-- ---------- REVISION CREATION INTEGRITY -------------------------------------
CREATE OR REPLACE FUNCTION retail.r1a_prepare_revision()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, retail, arb
AS $$
DECLARE
  v_target_watchlist bigint;
  v_doc jsonb;
  v_hash text;
BEGIN
  SELECT upstream_watchlist_id INTO v_target_watchlist
  FROM retail.search_targets
  WHERE id = NEW.target_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'R1A revision target % does not exist', NEW.target_id;
  END IF;

  IF NEW.upstream_watchlist_id IS DISTINCT FROM v_target_watchlist THEN
    RAISE EXCEPTION 'R1A revision watchlist does not match target watchlist';
  END IF;

  v_doc := retail.r1a_current_upstream_document(NEW.upstream_watchlist_id);
  IF v_doc IS NULL THEN
    RAISE EXCEPTION 'R1A revision blocked: upstream watchlist % missing', NEW.upstream_watchlist_id;
  END IF;

  v_hash := retail.r1a_sha256_jsonb(v_doc);

  -- Snapshot and hash are DB-owned, never trusted from the caller.
  NEW.upstream_snapshot := v_doc;
  NEW.upstream_snapshot_hash := v_hash;

  -- Strong direct drift protections.
  IF NEW.upstream_strategy_id IS DISTINCT FROM
       NULLIF(v_doc #>> '{watchlist,strategy_id}','')::bigint THEN
    RAISE EXCEPTION 'R1A revision blocked: strategy drift';
  END IF;
  IF NEW.category_key IS DISTINCT FROM v_doc #>> '{watchlist,category_key}' THEN
    RAISE EXCEPTION 'R1A revision blocked: category drift';
  END IF;
  IF NEW.family_key IS DISTINCT FROM v_doc #>> '{watchlist,family_key}' THEN
    RAISE EXCEPTION 'R1A revision blocked: family identity drift';
  END IF;

  NEW.revision_hash :=
    retail.r1a_sha256_jsonb(retail.r1a_revision_business_document(NEW));

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1a_prepare_revision
  ON retail.search_target_revisions;
CREATE TRIGGER trg_r1a_prepare_revision
BEFORE INSERT ON retail.search_target_revisions
FOR EACH ROW EXECUTE FUNCTION retail.r1a_prepare_revision();

CREATE OR REPLACE FUNCTION retail.r1a_revision_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'R1A target revisions cannot be deleted';
  END IF;

  -- Only approval lifecycle metadata can change after creation.
  IF (to_jsonb(NEW) - ARRAY['approval_status','approved_by','approved_at'])
     IS DISTINCT FROM
     (to_jsonb(OLD) - ARRAY['approval_status','approved_by','approved_at']) THEN
    RAISE EXCEPTION
      'R1A revision business content is immutable; create a new revision';
  END IF;

  -- Approval lifecycle is monotonic:
  -- pending -> approved|rejected
  -- approved -> superseded
  -- rejected/superseded are terminal.
  IF NEW.approval_status IS DISTINCT FROM OLD.approval_status THEN
    IF OLD.approval_status = 'pending'
       AND NEW.approval_status NOT IN ('approved','rejected') THEN
      RAISE EXCEPTION 'Invalid R1A revision transition: % -> %',
        OLD.approval_status, NEW.approval_status;
    ELSIF OLD.approval_status = 'approved'
       AND NEW.approval_status <> 'superseded' THEN
      RAISE EXCEPTION 'Invalid R1A revision transition: % -> %',
        OLD.approval_status, NEW.approval_status;
    ELSIF OLD.approval_status IN ('rejected','superseded') THEN
      RAISE EXCEPTION 'R1A revision state % is terminal', OLD.approval_status;
    END IF;
  END IF;

  IF NEW.approval_status = 'approved'
     AND (NEW.approved_by IS NULL OR NEW.approved_at IS NULL) THEN
    RAISE EXCEPTION 'Approved R1A revision requires approved_by and approved_at';
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1a_revision_immutable
  ON retail.search_target_revisions;
CREATE TRIGGER trg_r1a_revision_immutable
BEFORE UPDATE OR DELETE ON retail.search_target_revisions
FOR EACH ROW EXECUTE FUNCTION retail.r1a_revision_immutable();

-- ---------- CURRENTNESS / FAIL-CLOSED AUTHORITY -----------------------------
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
  SELECT COALESCE((
    SELECT
      t.upstream_watchlist_id = r.upstream_watchlist_id
      AND w.status = 'active'
      AND COALESCE(w.is_accessory,false) = false
      AND cw.is_enabled = true
      AND r.upstream_strategy_id IS NOT DISTINCT FROM w.strategy_id
      AND r.category_key = w.category_key
      AND r.family_key = w.family_key
      AND r.upstream_snapshot_hash =
          retail.r1a_current_upstream_hash(t.upstream_watchlist_id)
      AND (
        w.strategy_id IS NULL
        OR (ms.id = w.strategy_id AND ms.is_active = true)
      )
    FROM retail.search_targets t
    JOIN retail.search_target_revisions r
      ON r.target_id = t.id
     AND r.revision_no = p_revision_no
    JOIN arb.product_watchlist w
      ON w.id = t.upstream_watchlist_id
    JOIN arb.category_whitelist cw
      ON cw.category_key = w.category_key
    LEFT JOIN arb.market_category_strategy ms
      ON ms.id = w.strategy_id
    WHERE t.id = p_target_id
  ), false)
$$;

CREATE OR REPLACE FUNCTION retail.r1a_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  IF NEW.status = 'paused' AND OLD.status IS DISTINCT FROM 'paused' THEN
    NEW.paused_at := now();
  END IF;
  IF NEW.status = 'retired' AND OLD.status IS DISTINCT FROM 'retired' THEN
    NEW.retired_at := now();
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1a_targets_touch ON retail.search_targets;
CREATE TRIGGER trg_r1a_targets_touch
BEFORE UPDATE ON retail.search_targets
FOR EACH ROW EXECUTE FUNCTION retail.r1a_touch_updated_at();

CREATE OR REPLACE FUNCTION retail.r1a_validate_activation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_revision_status text;
  v_revision_watchlist bigint;
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.status = 'retired'
     AND NEW.status IS DISTINCT FROM 'retired' THEN
    RAISE EXCEPTION 'Retired R1A target cannot be reactivated or unretired';
  END IF;

  IF NEW.status = 'active' THEN
    IF NEW.current_revision_no <= 0 THEN
      RAISE EXCEPTION 'R1A activation requires current_revision_no > 0';
    END IF;

    SELECT approval_status, upstream_watchlist_id
      INTO v_revision_status, v_revision_watchlist
    FROM retail.search_target_revisions
    WHERE target_id = NEW.id
      AND revision_no = NEW.current_revision_no;

    IF v_revision_status IS DISTINCT FROM 'approved'
       OR v_revision_watchlist IS DISTINCT FROM NEW.upstream_watchlist_id THEN
      RAISE EXCEPTION
        'R1A activation blocked: current revision missing, unapproved, or mismatched';
    END IF;

    IF retail.r1a_revision_is_current(NEW.id, NEW.current_revision_no) IS NOT TRUE THEN
      RAISE EXCEPTION
        'R1A activation blocked: revision is stale or upstream authority is invalid';
    END IF;

    IF NEW.approved_by IS NULL OR NEW.approved_at IS NULL THEN
      RAISE EXCEPTION 'R1A activation requires approved_by and approved_at';
    END IF;

    NEW.activated_at := COALESCE(NEW.activated_at, now());
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_r1a_targets_validate_activation
  ON retail.search_targets;
CREATE TRIGGER trg_r1a_targets_validate_activation
BEFORE INSERT OR UPDATE OF
  status,current_revision_no,upstream_watchlist_id,approved_by,approved_at
ON retail.search_targets
FOR EACH ROW EXECUTE FUNCTION retail.r1a_validate_activation();

-- The ONLY executable R1A authority downstream domains may consume.
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
JOIN arb.product_watchlist w
  ON w.id = t.upstream_watchlist_id
JOIN arb.category_whitelist cw
  ON cw.category_key = w.category_key
LEFT JOIN arb.market_category_strategy ms
  ON ms.id = w.strategy_id
WHERE t.status = 'active'
  AND w.status = 'active'
  AND COALESCE(w.is_accessory,false) = false
  AND cw.is_enabled = true
  AND r.upstream_watchlist_id = w.id
  AND r.upstream_strategy_id IS NOT DISTINCT FROM w.strategy_id
  AND r.category_key = w.category_key
  AND r.family_key = w.family_key
  AND (w.strategy_id IS NULL OR (ms.id = w.strategy_id AND ms.is_active = true))
  AND r.upstream_snapshot_hash =
      retail.r1a_current_upstream_hash(t.upstream_watchlist_id)
  AND retail.r1a_sha256_jsonb(retail.r1a_revision_business_document(r)) =
      r.revision_hash;

COMMENT ON VIEW retail.effective_search_targets IS
'R1A sole executable authority. R1B/R1C/R1D must never dispatch from retail.search_targets directly.';

-- ---------- ACTOR-CORRECT AUDIT ---------------------------------------------
-- Dedicated R1A audit function: do not overwrite any pre-existing retail audit
-- function used by other retail tables.
CREATE OR REPLACE FUNCTION retail_audit.r1a_log_retail_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, retail_audit
AS $$
DECLARE
  v_row jsonb;
  v_pk text;
  v_actor text;
BEGIN
  v_row := CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  v_pk := COALESCE(v_row->>'id','');

  v_actor := COALESCE(
    NULLIF(current_setting('app.actor_name', true),''),
    NULLIF(current_setting('app.actor_id', true),''),
    session_user
  );

  INSERT INTO retail_audit.retail_change_log(
    schema_name, table_name, operation, row_pk,
    old_data, new_data, changed_by
  )
  VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    TG_OP,
    v_pk,
    CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) ELSE NULL END,
    CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) ELSE NULL END,
    v_actor
  );

  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;

DROP TRIGGER IF EXISTS trg_r1a_audit_search_targets ON retail.search_targets;
CREATE TRIGGER trg_r1a_audit_search_targets
AFTER INSERT OR UPDATE OR DELETE ON retail.search_targets
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1a_log_retail_change();

DROP TRIGGER IF EXISTS trg_r1a_audit_search_target_revisions
  ON retail.search_target_revisions;
CREATE TRIGGER trg_r1a_audit_search_target_revisions
AFTER INSERT OR UPDATE OR DELETE ON retail.search_target_revisions
FOR EACH ROW EXECUTE FUNCTION retail_audit.r1a_log_retail_change();

-- ---------- STRUCTURAL ASSERTIONS -------------------------------------------
DO $$
BEGIN
  IF to_regclass('arb.product_watchlist') IS NULL
     OR to_regclass('arb.market_category_strategy') IS NULL
     OR to_regclass('arb.category_whitelist') IS NULL
     OR to_regclass('arb.process_runs') IS NULL
     OR to_regclass('retail_audit.retail_change_log') IS NULL THEN
    RAISE EXCEPTION 'R1A V2 postflight failed: required ARB/Retail authority objects are missing';
  END IF;
END $$;

COMMIT;
