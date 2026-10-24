import type {PoolClient} from 'pg';
import type {GeographyExclusionRule, SourcePolicy} from '../core/types.js';

type Dataset = 'CBP' | 'ZBP';
export type ExceptionRow = {
  record_id: string;
  record_sha256: string;
  canonical_key: string;
  field_value: string;
};

const sources: {dataset: Dataset; sourceKey: string; field: 'county' | 'zip'}[] = [
  {dataset: 'CBP', sourceKey: 'CENSUS_CBP', field: 'county'},
  {dataset: 'ZBP', sourceKey: 'CENSUS_ZBP', field: 'zip'},
];
export type ReportOptions = {releaseIds: Partial<Record<Dataset, string>>; hudReleaseKey?: string};

export function exceptionReason(row: ExceptionRow, rules: GeographyExclusionRule[], counts: Map<string, number>): {
  reasonCode: string;
  policyStatus: 'APPROVED_EXCLUSION' | 'UNRESOLVED';
} {
  const rule = rules.find(item => item.value === row.field_value);
  if (!rule) return {reasonCode: 'MISSING_ZSL2_CANONICAL_LOCATION', policyStatus: 'UNRESOLVED'};
  if (counts.get(rule.value) !== rule.expectedCount)
    return {reasonCode: 'GEOGRAPHY_EXCLUSION_COUNT_MISMATCH', policyStatus: 'UNRESOLVED'};
  return {reasonCode: rule.reasonCode, policyStatus: 'APPROVED_EXCLUSION'};
}

export async function reportGeographyExceptions(c: PoolClient, policy: SourcePolicy,
  options: ReportOptions, emit: (line: object) => void): Promise<void> {
  for (const source of sources) {
    const releaseId = options.releaseIds[source.dataset];
    if (!releaseId) continue;
    const rules = policy.geographyExclusionRules.filter(rule => rule.sourceKey === source.sourceKey &&
      rule.field === source.field && rule.sourceReleaseId === releaseId);
    const policyReleaseMatches = policy.geographyExclusionRules.some(rule =>
      rule.sourceKey === source.sourceKey && rule.sourceReleaseId === releaseId);
    const geography = source.dataset === 'ZBP' ? 'POSTAL_CODE' : 'COUNTY';
    const sourceCount = await c.query<{record_count: string}>(
      `SELECT count(*)::text AS record_count FROM zsl.certified_release_records
       WHERE release_id = $1 AND source_key = $2`, [releaseId, source.sourceKey]);
    if (Number(sourceCount.rows[0]?.record_count ?? 0) === 0)
      throw new Error(`PINNED_RELEASE_HAS_NO_CERTIFIED_RECORDS:${source.sourceKey}:${releaseId}`);
    let hudZips: Set<string> | null = null;
    if (source.dataset === 'ZBP') {
      if (!options.hudReleaseKey) throw new Error('HUD_RELEASE_KEY_REQUIRED');
      const hud = await c.query<{zip: string}>(
        `SELECT DISTINCT record->>'zip' AS zip FROM zsl.certified_release_records
         WHERE source_key='HUD_USPS_ZIP_COUNTY' AND release_key=$1`, [options.hudReleaseKey]);
      if (hud.rows.length === 0) throw new Error(`HUD_RELEASE_HAS_NO_CERTIFIED_RECORDS:${options.hudReleaseKey}`);
      hudZips = new Set(hud.rows.map(row => row.zip));
    }
    const canonicalKey = source.dataset === 'ZBP'
      ? `('US:ZIP:' || lpad(coalesce(r.record->>'ZIPCODE', r.record->>'zip code', r.record->>'zip'), 5, '0'))`
      : `('US:COUNTY:' || lpad(coalesce(r.record->>'state', r.record->>'STATE'), 2, '0') || lpad(coalesce(r.record->>'county', r.record->>'COUNTY'), 3, '0'))`;
    const fieldValue = source.dataset === 'ZBP'
      ? `lpad(coalesce(r.record->>'ZIPCODE', r.record->>'zip code', r.record->>'zip'), 5, '0')`
      : `lpad(coalesce(r.record->>'county', r.record->>'COUNTY'), 3, '0')`;
    const result = await c.query<ExceptionRow>(`
      SELECT r.record_id::text, r.record_sha256, ${canonicalKey} AS canonical_key,
             ${fieldValue} AS field_value
      FROM zsl.certified_release_records r
      LEFT JOIN zsl.certified_canonical_locations loc ON loc.canonical_key = ${canonicalKey}
      WHERE r.release_id = $1 AND (loc.canonical_key IS NULL OR ${fieldValue} = ANY($2::text[]))
      ORDER BY r.record_id
    `, [releaseId, rules.map(rule => rule.value)]);
    const counts = new Map(rules.map(rule => [rule.value, result.rows.filter(row => row.field_value === rule.value).length]));
    const ruleCountMismatches = rules.filter(rule => counts.get(rule.value) !== rule.expectedCount)
      .map(rule => ({value: rule.value, expected: rule.expectedCount, actual: counts.get(rule.value) ?? 0}));
    let approved = 0;
    let unresolved = 0;
    const unmatchedZips = new Set<string>();
    const matchedHudZips = new Set<string>();
    for (const row of result.rows) {
      const outcome = exceptionReason(row, rules, counts);
      if (outcome.policyStatus === 'APPROVED_EXCLUSION') approved++;
      else unresolved++;
      const zip = row.canonical_key?.startsWith('US:ZIP:') ? row.canonical_key.slice(7) : null;
      if (source.dataset === 'ZBP' && zip) {
        unmatchedZips.add(zip);
        if (hudZips?.has(zip)) matchedHudZips.add(zip);
      }
      emit({type: 'record', dataset: source.dataset, sourceKey: source.sourceKey,
        releaseId, geography, sourceRecordId: row.record_id, sourceRecordSha256: row.record_sha256,
        canonicalKey: row.canonical_key, fieldValue: row.field_value, ...outcome,
        hudReleaseKey: source.dataset === 'ZBP' ? options.hudReleaseKey : null,
        hudStatus: source.dataset === 'ZBP'
          ? hudZips?.has(zip ?? '') ? 'IN_SELECTED_HUD_SNAPSHOT' : 'NOT_IN_SELECTED_HUD_SNAPSHOT'
          : 'NOT_APPLICABLE'});
    }
    emit({type: 'summary', dataset: source.dataset, releaseId,
      certifiedSourceRecords: Number(sourceCount.rows[0].record_count), reported: result.rows.length,
      distinctExceptionZips: source.dataset === 'ZBP' ? unmatchedZips.size : null,
      distinctExceptionZipsInHud: source.dataset === 'ZBP' ? matchedHudZips.size : null,
      hudReleaseKey: source.dataset === 'ZBP' ? options.hudReleaseKey : null,
      policyReleaseMatches, approvedExclusions: approved, unresolved, ruleCountMismatches,
      certificationDecision: unresolved || ruleCountMismatches.length ? 'BLOCKED' : 'NOT_ASSESSED'});
  }
}
