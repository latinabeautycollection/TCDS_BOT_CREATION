import { Pool } from 'pg';

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const ALLOW_EMPTY = process.env.R1A_CERT_ALLOW_EMPTY_BASELINE === 'true';

type Check = { gate: number; name: string; ok: boolean; detail: unknown };

async function main() {
  const c = await pool.connect();
  try {
    const checks: Check[] = [];
    const add = (gate: number, name: string, ok: boolean, detail: unknown) =>
      checks.push({ gate, name, ok, detail });

    const reg = await c.query(`
      select
        to_regclass('retail.r1a_schema_state') state,
        to_regclass('retail.search_targets') targets,
        to_regclass('retail.search_target_revisions') revisions,
        to_regclass('retail.effective_search_targets') effective,
        to_regclass('retail_audit.retail_change_log') audit,
        to_regclass('arb.product_watchlist') watchlist,
        to_regclass('arb.market_category_strategy') strategy,
        to_regclass('arb.category_whitelist') category,
        to_regclass('arb.process_runs') process_runs
    `);
    add(1, 'required_authority_objects',
      Object.values(reg.rows[0]).every(Boolean), reg.rows[0]);

    const badWatch = await c.query(`
      select count(*)::int n
      from retail.effective_search_targets e
      join arb.product_watchlist w on w.id=e.upstream_watchlist_id
      where w.status<>'active'
    `);
    add(2, 'inactive_watchlist_cannot_execute', badWatch.rows[0].n === 0, badWatch.rows[0]);

    const badCat = await c.query(`
      select count(*)::int n
      from retail.effective_search_targets e
      join arb.product_watchlist w on w.id=e.upstream_watchlist_id
      left join arb.category_whitelist cw on cw.category_key=w.category_key
      where coalesce(cw.is_enabled,false)=false
    `);
    add(3, 'disabled_category_cannot_execute', badCat.rows[0].n === 0, badCat.rows[0]);

    const badStrategy = await c.query(`
      select count(*)::int n
      from retail.effective_search_targets e
      join arb.product_watchlist w on w.id=e.upstream_watchlist_id
      left join arb.market_category_strategy ms on ms.id=w.strategy_id
      where w.strategy_id is not null and coalesce(ms.is_active,false)=false
    `);
    add(4, 'inactive_strategy_cannot_execute', badStrategy.rows[0].n === 0, badStrategy.rows[0]);

    const strategyDrift = await c.query(`
      select count(*)::int n
      from retail.effective_search_targets e
      join arb.product_watchlist w on w.id=e.upstream_watchlist_id
      where e.upstream_strategy_id is distinct from w.strategy_id
    `);
    add(5, 'strategy_drift_blocked', strategyDrift.rows[0].n === 0, strategyDrift.rows[0]);

    const categoryDrift = await c.query(`
      select count(*)::int n
      from retail.effective_search_targets e
      join arb.product_watchlist w on w.id=e.upstream_watchlist_id
      where e.category_key is distinct from w.category_key
    `);
    add(6, 'category_drift_blocked', categoryDrift.rows[0].n === 0, categoryDrift.rows[0]);

    const familyDrift = await c.query(`
      select count(*)::int n
      from retail.effective_search_targets e
      join retail.r1a_authorized_watchlist a
        on a.watchlist_id=e.upstream_watchlist_id
      where e.family_key is distinct from a.cohort_product_key
         or e.canonical_product_key is distinct from a.cohort_product_key
    `);
    add(
      7,
      'curated_candidate_identity_drift_blocked',
      familyDrift.rows[0].n === 0,
      familyDrift.rows[0]
    );

    const stale = await c.query(`
      select count(*)::int n
      from retail.effective_search_targets e
      where e.upstream_snapshot_hash
        is distinct from retail.r1a_current_upstream_hash(e.upstream_watchlist_id)
    `);
    add(8, 'upstream_keyword_and_policy_drift_blocked', stale.rows[0].n === 0, stale.rows[0]);

    const accessory = await c.query(`
      select count(*)::int n
      from retail.effective_search_targets e
      join arb.product_watchlist w on w.id=e.upstream_watchlist_id
      where coalesce(w.is_accessory,false)=true
    `);
    add(9, 'accessory_classification_blocks_execution', accessory.rows[0].n === 0, accessory.rows[0]);

    const unapproved = await c.query(`
      select count(*)::int n
      from retail.effective_search_targets e
      join retail.search_target_revisions r on r.id=e.revision_id
      where r.approval_status<>'approved'
    `);
    add(10, 'unapproved_revision_cannot_execute', unapproved.rows[0].n === 0, unapproved.rows[0]);

    const supersededCurrent = await c.query(`
      select count(*)::int n
      from retail.search_targets t
      join retail.search_target_revisions r
        on r.target_id=t.id and r.revision_no=t.current_revision_no
      where t.status='active' and r.approval_status='superseded'
    `);
    add(11, 'superseded_revision_not_current', supersededCurrent.rows[0].n === 0, supersededCurrent.rows[0]);

    const immutabilityTrigger = await c.query(`
      select count(*)::int n
      from pg_trigger
      where tgrelid='retail.search_target_revisions'::regclass
        and tgname='trg_r1a_revision_immutable'
        and not tgisinternal
    `);
    add(12, 'revision_immutability_trigger_installed',
      immutabilityTrigger.rows[0].n === 1, immutabilityTrigger.rows[0]);

    const badHash = await c.query(`
      select count(*)::int n
      from retail.search_target_revisions r
      where retail.r1a_sha256_jsonb(retail.r1a_revision_business_document(r))
            <> r.revision_hash
    `);
    add(13, 'revision_hash_reproducible', badHash.rows[0].n === 0, badHash.rows[0]);

    const actorAuditFn = await c.query(`
      select pg_get_functiondef('retail_audit.r1a_log_retail_change()'::regprocedure) def
    `);
    const def = String(actorAuditFn.rows[0]?.def ?? '');
    add(14, 'actor_correct_audit',
      def.includes("app.actor_name") &&
      def.includes("app.actor_id") &&
      def.includes("session_user"),
      { actor_context: true });

    const purchaseColumns = await c.query(`
      select column_name
      from information_schema.columns
      where table_schema='retail'
        and table_name in ('search_targets','search_target_revisions')
        and (
          column_name ilike '%purchase_author%'
          or column_name ilike '%checkout%'
          or column_name ilike '%capital_alloc%'
          or column_name = 'hard_max_buy_price'
          or column_name = 'max_buy_price'
        )
      order by column_name
    `);
    add(15, 'no_purchase_or_capital_authority_in_r1a',
      purchaseColumns.rowCount === 0, purchaseColumns.rows);

    const viewDef = await c.query(`
      select pg_get_viewdef('retail.effective_search_targets'::regclass,true) def
    `);
    const viewSql = String(viewDef.rows[0]?.def ?? '');
    add(16, 'effective_view_is_fail_closed_authority',
      viewSql.includes('r1a_current_upstream_hash') &&
      viewSql.includes('revision_hash') &&
      viewSql.includes("w.status = 'active'") &&
      viewSql.includes('cw.is_enabled'),
      { effective_view_verified: true });

    const effective = await c.query(
      `select count(*)::int n from retail.effective_search_targets`
    );
    const nonEmptyOk = ALLOW_EMPTY || effective.rows[0].n > 0;

    const certified = checks.every(x => x.ok) && nonEmptyOk;
    const result = {
      certification: certified ? 'CERTIFIED' : 'FAILED',
      schemaVersion: '2.0.0',
      effectiveTargetCount: effective.rows[0].n,
      emptyBaselineAllowed: ALLOW_EMPTY,
      emptyBaselineGate: nonEmptyOk,
      checks
    };

    console.log(JSON.stringify(result, null, 2));
    if (!certified) process.exitCode = 2;
  } finally {
    c.release();
    await pool.end();
  }
}

main().catch(e => {
  console.error(e);
  process.exitCode = 1;
});
