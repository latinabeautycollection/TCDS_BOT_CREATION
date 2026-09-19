import { randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { Pool, PoolClient } from 'pg';
import type { ArbWatchlistRow, PriorityTier } from './types';

const pool = new Pool({ connectionString: process.env.DATABASE_URL });

const ACTOR_ID = process.env.R1A_ACTOR_ID ?? 'retail-r1a-sync';
const ACTOR_NAME = process.env.R1A_ACTOR_NAME ?? 'R1A Sync Service';
const CODE_VERSION = process.env.CODE_VERSION ?? process.env.GIT_SHA ?? 'unknown';
const RULESET_VERSION = 'r1a-v2.1.0-curated-exact';

function norm(v: unknown): string {
  return String(v ?? '').trim();
}

function dedupeSorted(values: Array<string | null | undefined>): string[] {
  return [...new Set(values.map(norm).filter(Boolean).map(v => v.toLowerCase()))]
    .sort((a, b) => a.localeCompare(b));
}

function storageTerms(value: unknown): string[] {
  return [
    ...norm(value).matchAll(/\b(\d+(?:\.\d+)?)\s*(gb|tb)\b/gi)
  ].map(match => `${match[1]} ${match[2].toLowerCase()}`);
}

function priority(score: number | null): PriorityTier {
  const s = Number(score ?? 0);
  if (s >= 90) return 'A_PLUS';
  if (s >= 80) return 'A';
  if (s >= 65) return 'B';
  if (s >= 50) return 'C';
  return 'D';
}

async function setActorContext(
  c: PoolClient,
  processRunId: string,
  correlationId: string
): Promise<void> {
  await c.query(`select set_config('app.actor_type','service_account',true)`);
  await c.query(`select set_config('app.actor_id',$1,true)`, [ACTOR_ID]);
  await c.query(`select set_config('app.actor_name',$1,true)`, [ACTOR_NAME]);
  await c.query(`select set_config('app.process_run_id',$1,true)`, [processRunId]);
  await c.query(`select set_config('app.correlation_id',$1,true)`, [correlationId]);
}

async function startProcessRun(): Promise<{ runId: string; correlationId: string }> {
  const correlationId = randomUUID();
  const r = await pool.query(
    `insert into arb.process_runs(
       process_name, process_stage, status, correlation_id,
       actor_type, actor_id, actor_name,
       worker_name, worker_instance_id,
       code_version, ruleset_version,
       entity_type, idempotency_key, details_json
     )
     values(
       'RETAIL_R1A_TARGET_SYNC','SYNC','STARTED',$1,
       'service_account',$2,$3,
       'r1a-sync',coalesce($4,'r1a-sync-1'),
       $5,$6,
       'arb.product_watchlist',$7,
       jsonb_build_object('r1a_schema_version','2.0.0')
     )
     returning run_id`,
    [
      correlationId,
      ACTOR_ID,
      ACTOR_NAME,
      process.env.WORKER_INSTANCE_ID ?? null,
      CODE_VERSION,
      RULESET_VERSION,
      `R1A_SYNC:${correlationId}`
    ]
  );
  return { runId: r.rows[0].run_id, correlationId };
}

async function finishProcessRun(
  runId: string,
  status: 'SUCCEEDED' | 'FAILED',
  counts: { seen: number; succeeded: number; failed: number },
  error?: unknown
): Promise<void> {
  await pool.query(
    `update arb.process_runs
        set status=$2,
            rows_seen=$3,
            rows_succeeded=$4,
            rows_failed=$5,
            entity_count=$3,
            error_class=$6,
            error_summary=$7,
            completed_at=case when $2='SUCCEEDED' then now() else completed_at end,
            failed_at=case when $2='FAILED' then now() else failed_at end,
            updated_at=now()
      where run_id=$1`,
    [
      runId,
      status,
      counts.seen,
      counts.succeeded,
      counts.failed,
      error ? (error as Error).name ?? 'Error' : null,
      error ? String((error as Error).message ?? error).slice(0, 2000) : null
    ]
  );
}

async function buildOne(
  c: PoolClient,
  w: ArbWatchlistRow,
  processRunId: string,
  correlationId: string
) {
  // Current upstream truth and hash come from PostgreSQL, never JS serialization.
  const authority = await c.query(
    `select
       retail.r1a_current_upstream_document($1) as doc,
       retail.r1a_current_upstream_hash($1) as hash`,
    [w.id]
  );
  if (!authority.rowCount || !authority.rows[0].doc) {
    return { skipped: true, reason: 'UPSTREAM_MISSING', watchlistId: w.id };
  }

  const doc = authority.rows[0].doc;
  const strategy = doc.strategy ?? null;
  const categoryAuthority = doc.category_authority ?? null;

  if (w.status !== 'active') {
    return { skipped: true, reason: 'WATCHLIST_INACTIVE', watchlistId: w.id };
  }
  if (w.is_accessory === true) {
    return { skipped: true, reason: 'ACCESSORY_BLOCKED', watchlistId: w.id };
  }
  if (!categoryAuthority || categoryAuthority.is_enabled !== true) {
    return { skipped: true, reason: 'CATEGORY_DISABLED', watchlistId: w.id };
  }
  if (w.strategy_id != null && (!strategy || strategy.is_active !== true)) {
    return { skipped: true, reason: 'STRATEGY_INACTIVE', watchlistId: w.id };
  }

  const extractedStorageTerms = storageTerms(w.cohort_title);

  const includeTerms = dedupeSorted([
    ...(strategy?.include_keywords ?? []),
    w.cohort_brand,
    w.cohort_model,
    w.cohort_mpn,
    w.cohort_ebay_mpn_seen,
    w.cohort_normalized_brand,
    w.cohort_normalized_product_type,
    w.cohort_normalized_model_family,
    w.cohort_normalized_model_token,
    w.cohort_normalized_generation,
    w.cohort_normalized_variant,
    w.cohort_normalized_storage,
    ...extractedStorageTerms
  ]);

  const excludeTerms = dedupeSorted([
    ...(strategy?.exclude_keywords ?? []),
    'activation locked',
    'icloud locked',
    'for parts',
    'parts only',
    'dummy phone',
    'empty box',
    'case only',
    'screen protector'
  ]);

  // Conditions are product state. Clearance/closeout/etc. remain merchandising
  // or source signals and cannot be treated as product conditions.
  const allowedConditions = ['new', 'open_box', 'refurbished'];
  const desiredSourceTypes = [
    'clearance', 'closeout', 'outlet', 'refurbished',
    'open_box', 'overstock', 'special_buy', 'sale'
  ];
  const desiredDiscountSignals = [
    'price_reduction', 'clearance_badge', 'closeout_badge',
    'outlet_source', 'refurbished_condition', 'open_box_condition'
  ];

  let target = await c.query(
    `select *
       from retail.search_targets
      where upstream_watchlist_id=$1
      for update`,
    [w.id]
  );

  if (!target.rowCount) {
    target = await c.query(
      `insert into retail.search_targets(
         target_code, upstream_watchlist_id, status, created_by,
         last_sync_process_run_id, last_sync_correlation_id
       )
       values($1,$2,'draft',$3,$4,$5)
       returning *`,
      [`ARB_WL_${w.id}`, w.id, ACTOR_NAME, processRunId, correlationId]
    );
  }

  const t = target.rows[0];

  // If the currently approved revision is stale, pause the target immediately.
  // The effective view already fails closed even before this reconciliation.
  if (t.status === 'active' && t.current_revision_no > 0) {
    const cur = await c.query(
      `select retail.r1a_revision_is_current($1,$2) as is_current`,
      [t.id, t.current_revision_no]
    );
    if (cur.rows[0]?.is_current !== true) {
      await c.query(
        `update retail.search_targets
            set status='paused',
                last_sync_process_run_id=$2,
                last_sync_correlation_id=$3
          where id=$1`,
        [t.id, processRunId, correlationId]
      );
    }
  }

  // Build the candidate revision. DB trigger overwrites upstream_snapshot,
  // upstream_snapshot_hash and revision_hash from current authoritative state.
  const nextNo = Number((
    await c.query(
      `select coalesce(max(revision_no),0)+1 as n
         from retail.search_target_revisions
        where target_id=$1`,
      [t.id]
    )
  ).rows[0].n);

  // We first compare a deterministic business signature in DB so identical
  // upstream intent does not create revision churn.
  const previous = await c.query(
    `select
       r.*,
       r.search_policy - 'category_rank' as stable_search_policy,
       retail.r1a_stable_upstream_document(r.upstream_snapshot) =
         retail.r1a_stable_upstream_document(
           retail.r1a_current_upstream_document(r.upstream_watchlist_id)
         ) as upstream_snapshot_current
       from retail.search_target_revisions r
      where r.target_id=$1
      order by r.revision_no desc
      limit 1`,
    [t.id]
  );

  const candidate = {
    upstream_watchlist_id: w.id,
    upstream_strategy_id: w.strategy_id,
    category_key: w.category_key,
    family_key: w.cohort_product_key,
    family_name: norm(w.cohort_title) || w.family_name,
    canonical_product_key: w.cohort_product_key,
    brand: w.cohort_brand ?? w.cohort_normalized_brand ?? w.brand,
    model_family:
      w.cohort_normalized_model_family ?? w.cohort_model ?? w.model_family,
    normalized_product_type:
      w.cohort_normalized_product_type ?? w.normalized_product_type,
    normalized_model_token:
      w.cohort_normalized_model_token ?? w.normalized_model_token,
    normalized_generation:
      w.cohort_normalized_generation ?? w.normalized_generation,
    normalized_variant:
      w.cohort_normalized_variant ?? w.normalized_variant,
    normalized_storage:
      w.cohort_normalized_storage ?? extractedStorageTerms[0] ?? null,
    normalized_platform:
      w.cohort_normalized_platform ?? w.normalized_platform,
    upstream_identity_confidence:
      w.cohort_identity_confidence ?? w.identity_confidence,
    keyword_fingerprint: includeTerms.join('|'),
    include_terms: includeTerms,
    exclude_terms: excludeTerms,
    allowed_conditions: allowedConditions,
    desired_source_types: desiredSourceTypes,
    desired_discount_signals: desiredDiscountSignals,
    discovery_price_ceiling_usd:
      w.predicted_buy_cost_usd == null ? null : Number(w.predicted_buy_cost_usd),
    discovery_result_limit: 100,
    priority_tier: priority(w.overall_watch_score),
    search_policy: {
      origin: 'arb.product_watchlist',
      product_authority: 'public.prong2_top500_items',
      authority_policy: 'r1a-curated-exact-v1',
      identity_source: 'curated_candidate',
      r1a_schema_version: '2.0.0',
      cohort_product_key: w.cohort_product_key,
      representative_candidate_id: String(w.representative_candidate_id),
      source_title: w.cohort_title,
      source_model: w.cohort_model,
      source_mpn: w.cohort_mpn,
      source_condition_text: w.cohort_condition_text,
      match_class: w.cohort_match_class,
      match_score: Number(w.cohort_best_match_score),
      category_limit: Number(w.max_products_per_run),
      purchase_authority: false,
      capital_authority: false,
      source_routing_authority: false,
      location_routing_authority: false
    }
  };

  if (previous.rowCount) {
    const p = previous.rows[0];
    const same =
      Number(p.upstream_watchlist_id) === Number(candidate.upstream_watchlist_id) &&
      (p.upstream_strategy_id == null ? null : Number(p.upstream_strategy_id)) ===
        (candidate.upstream_strategy_id == null ? null : Number(candidate.upstream_strategy_id)) &&
      p.category_key === candidate.category_key &&
      p.family_key === candidate.family_key &&
      p.family_name === candidate.family_name &&
      p.canonical_product_key === candidate.canonical_product_key &&
      p.brand === candidate.brand &&
      p.model_family === candidate.model_family &&
      p.normalized_product_type === candidate.normalized_product_type &&
      p.normalized_model_token === candidate.normalized_model_token &&
      p.normalized_generation === candidate.normalized_generation &&
      p.normalized_variant === candidate.normalized_variant &&
      p.normalized_storage === candidate.normalized_storage &&
      p.normalized_platform === candidate.normalized_platform &&
      String(p.upstream_identity_confidence ?? '') === String(candidate.upstream_identity_confidence ?? '') &&
      p.keyword_fingerprint === candidate.keyword_fingerprint &&
      JSON.stringify(p.include_terms) === JSON.stringify(candidate.include_terms) &&
      JSON.stringify(p.exclude_terms) === JSON.stringify(candidate.exclude_terms) &&
      JSON.stringify(p.allowed_conditions) === JSON.stringify(candidate.allowed_conditions) &&
      JSON.stringify(p.desired_source_types) === JSON.stringify(candidate.desired_source_types) &&
      JSON.stringify(p.desired_discount_signals) === JSON.stringify(candidate.desired_discount_signals) &&
      String(p.discovery_price_ceiling_usd ?? '') === String(candidate.discovery_price_ceiling_usd ?? '') &&
      Number(p.discovery_result_limit) === candidate.discovery_result_limit &&
      p.priority_tier === candidate.priority_tier &&
      isDeepStrictEqual(p.stable_search_policy, candidate.search_policy) &&
      p.upstream_snapshot_current === true;

    if (same) {
      await c.query(
        `update retail.search_targets
            set last_sync_process_run_id=$2,
                last_sync_correlation_id=$3
          where id=$1`,
        [t.id, processRunId, correlationId]
      );
      return {
        skipped: true,
        reason: 'NO_CHANGE',
        targetId: t.id,
        revisionNo: p.revision_no
      };
    }
  }

  const inserted = await c.query(
    `insert into retail.search_target_revisions(
       target_id, revision_no,
       upstream_watchlist_id, upstream_strategy_id,
       category_key, family_key, family_name, canonical_product_key,
       brand, model_family,
       normalized_product_type, normalized_model_token,
       normalized_generation, normalized_variant, normalized_storage,
       normalized_platform, upstream_identity_confidence,
       keyword_fingerprint,
       include_terms, exclude_terms,
       allowed_conditions, desired_source_types, desired_discount_signals,
       discovery_price_ceiling_usd, discovery_result_limit, priority_tier,
       search_policy,
       upstream_snapshot, upstream_snapshot_hash, revision_hash,
       source_process_run_id, source_correlation_id, created_by
     )
     values(
       $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,
       $19::jsonb,$20::jsonb,$21::jsonb,$22::jsonb,$23::jsonb,
       $24,$25,$26,$27::jsonb,
       '{}'::jsonb, repeat('0',64), repeat('0',64),
       $28,$29,$30
     )
     returning id, revision_no, upstream_snapshot_hash, revision_hash`,
    [
      t.id, nextNo,
      candidate.upstream_watchlist_id, candidate.upstream_strategy_id,
      candidate.category_key, candidate.family_key, candidate.family_name,
      candidate.canonical_product_key, candidate.brand, candidate.model_family,
      candidate.normalized_product_type, candidate.normalized_model_token,
      candidate.normalized_generation, candidate.normalized_variant,
      candidate.normalized_storage, candidate.normalized_platform,
      candidate.upstream_identity_confidence, candidate.keyword_fingerprint,
      JSON.stringify(candidate.include_terms),
      JSON.stringify(candidate.exclude_terms),
      JSON.stringify(candidate.allowed_conditions),
      JSON.stringify(candidate.desired_source_types),
      JSON.stringify(candidate.desired_discount_signals),
      candidate.discovery_price_ceiling_usd,
      candidate.discovery_result_limit,
      candidate.priority_tier,
      JSON.stringify(candidate.search_policy),
      processRunId, correlationId, ACTOR_NAME
    ]
  );

  // New intent requires human/system approval; active target is paused until then.
  await c.query(
    `update retail.search_targets
        set status=case when status='retired' then status else 'paused' end,
            last_sync_process_run_id=$2,
            last_sync_correlation_id=$3
      where id=$1`,
    [t.id, processRunId, correlationId]
  );

  return {
    created: true,
    targetId: t.id,
    revisionNo: inserted.rows[0].revision_no,
    revisionHash: inserted.rows[0].revision_hash
  };
}

async function reconcileInvalidActiveTargets(
  c: PoolClient,
  processRunId: string,
  correlationId: string
): Promise<number> {
  const r = await c.query(
    `update retail.search_targets t
        set status='paused',
            last_sync_process_run_id=$1,
            last_sync_correlation_id=$2
      where t.status='active'
        and (
          t.current_revision_no <= 0
          or retail.r1a_revision_is_current(t.id,t.current_revision_no) is not true
        )
      returning t.id`,
    [processRunId, correlationId]
  );
  return r.rowCount ?? 0;
}

async function main() {
  const { runId, correlationId } = await startProcessRun();
  const c = await pool.connect();
  let seen = 0;
  let succeeded = 0;
  let failed = 0;

  try {
    await c.query('begin');
    await setActorContext(c, runId, correlationId);

    const paused = await reconcileInvalidActiveTargets(c, runId, correlationId);

    const rows = await c.query(
      `select w.*,
              a.cohort_product_key,
              a.representative_candidate_id,
              a.category_rank,
              a.max_products_per_run,
              p.brand as cohort_brand,
              p.model as cohort_model,
              p.mpn as cohort_mpn,
              p.ebay_mpn_seen as cohort_ebay_mpn_seen,
              p.title as cohort_title,
              p.normalized_title as cohort_normalized_title,
              p.normalized_brand as cohort_normalized_brand,
              c.normalized_product_type as cohort_normalized_product_type,
              p.normalized_model_family as cohort_normalized_model_family,
              p.normalized_model_token as cohort_normalized_model_token,
              p.normalized_generation as cohort_normalized_generation,
              p.normalized_variant as cohort_normalized_variant,
              p.normalized_storage as cohort_normalized_storage,
              p.normalized_platform as cohort_normalized_platform,
              p.condition_text as cohort_condition_text,
              p.identity_confidence as cohort_identity_confidence,
              c.best_match_score as cohort_best_match_score,
              c.best_match_reason_json #>> '{summary,matchClass}'
                as cohort_match_class
         from retail.r1a_authorized_watchlist a
         join arb.product_watchlist w on w.id=a.watchlist_id
         join public.prong2_top500_items p
           on p.representative_candidate_id=a.representative_candidate_id
         join arb.candidates c
           on c.id=a.representative_candidate_id
        order by a.category_key, a.category_rank, a.watchlist_id`
    );

    seen = rows.rowCount ?? 0;
    const results = [];
    for (const w of rows.rows as ArbWatchlistRow[]) {
      try {
        results.push(await buildOne(c, w, runId, correlationId));
        succeeded++;
      } catch (e) {
        failed++;
        throw e; // fail the entire sync: no partial R1A truth
      }
    }

    await c.query('commit');
    await finishProcessRun(runId, 'SUCCEEDED', { seen, succeeded, failed });

    console.log(JSON.stringify({
      event: 'r1a_sync_complete',
      processRunId: runId,
      correlationId,
      pausedStaleTargets: paused,
      count: results.length,
      results
    }, null, 2));
  } catch (e) {
    await c.query('rollback').catch(() => undefined);
    await finishProcessRun(runId, 'FAILED', { seen, succeeded, failed }, e);
    throw e;
  } finally {
    c.release();
    await pool.end();
  }
}

main().catch(e => {
  console.error(e);
  process.exitCode = 1;
});
