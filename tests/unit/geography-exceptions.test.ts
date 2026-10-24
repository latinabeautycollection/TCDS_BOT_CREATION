import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createHash} from 'node:crypto';
import type {PoolClient} from 'pg';
import type {SourcePolicy} from '../../src/core/types.js';
import {exceptionReason, reportGeographyExceptions, type ExceptionRow} from '../../src/normalizers/geography-exceptions.js';

const policy = JSON.parse(fs.readFileSync('config/source-policy.json', 'utf8')) as SourcePolicy;
const row = (value: string): ExceptionRow => ({record_id: value, record_sha256: 'a'.repeat(64),
  canonical_key: `US:ZIP:${value}`, field_value: value});

test('only exact, count-verified exclusions are approved', () => {
  const rules = policy.geographyExclusionRules.filter(rule => rule.sourceKey === 'CENSUS_ZBP');
  const report = fs.readFileSync('evidence/ZBP_HUD_2025Q4_NONMATCHES.csv');
  assert.equal(createHash('sha256').update(report).digest('hex'),
    policy.geographyExclusionEvidence?.zbpHud2025Q4.csvSha256);
  assert.equal(rules.length, 331);
  assert.equal(rules.reduce((sum, rule) => sum + rule.expectedCount, 0), 2030);
  const cbpRule = policy.geographyExclusionRules.find(rule => rule.sourceKey === 'CENSUS_CBP');
  assert.equal(cbpRule?.sourceReleaseId, 'f55687ff-46de-48bb-8875-d39b8032e6d0');
  assert.equal(cbpRule?.expectedCount, 10525);
  assert.equal(policy.geographyExclusionRules.reduce((sum, rule) => sum + rule.expectedCount, 0), 12555);
  assert.equal(policy.geographyExclusionEvidence?.cbpCounty2023?.sourceRecordCount, 10525);
  assert.equal(policy.geographyExclusionEvidence?.zbpHud2025Q4.csvSha256,
    'c114e4a3df618b2dee7fd351a27ea81efe51b4266b74d6ff50ed9c4bc0a95d03');
  assert.deepEqual(exceptionReason(row('38194'), rules, new Map([['38194', 11]])),
    {reasonCode: 'NOT_IN_HUD_2025_Q4', policyStatus: 'APPROVED_EXCLUSION'});
  assert.deepEqual(exceptionReason(row('38194'), rules, new Map([['38194', 2]])),
    {reasonCode: 'GEOGRAPHY_EXCLUSION_COUNT_MISMATCH', policyStatus: 'UNRESOLVED'});
  assert.deepEqual(exceptionReason(row('12345'), rules, new Map()),
    {reasonCode: 'MISSING_ZSL2_CANONICAL_LOCATION', policyStatus: 'UNRESOLVED'});
});

test('release manifest includes the exception evidence and excludes local Git internals', () => {
  const manifest = JSON.parse(fs.readFileSync('evidence/SOURCE_MANIFEST.json', 'utf8')) as Array<{path: string}>;
  assert.ok(manifest.some(item => item.path === 'evidence/ZBP_HUD_2025Q4_NONMATCHES.csv'));
  assert.ok(manifest.every(item => !item.path.startsWith('.git/')));
});

test('report uses current release and classifies each exception against stored HUD data', async () => {
  const output: object[] = [];
  const reportPolicy = {...policy, geographyExclusionRules: policy.geographyExclusionRules.filter(rule =>
    rule.sourceKey === 'CENSUS_ZBP' && rule.value === '38194')};
  const client = {async query(sql: string) {
    if (sql.includes('count(*)::text')) return {rows: [{record_count: '12'}]};
    if (sql.includes("record->>'zip' AS zip")) return {rows: [{zip: '12345'}]};
    if (!sql.includes('FROM zsl.certified_release_records')) throw new Error('unexpected query');
    return {rows: [...Array.from({length: 11}, (_, i) => ({...row('38194'), record_id: `38194-${i}`})), row('12345')]};
  }} as unknown as PoolClient;
  await reportGeographyExceptions(client, reportPolicy,
    {releaseIds: {ZBP: 'ace731d1-c607-4aac-b09d-959e1bbb341f'}, hudReleaseKey: '2025-Q4'},
    line => output.push(line));
  assert.equal(output.length, 13);
  assert.deepEqual(output.at(-1), {type: 'summary', dataset: 'ZBP',
    releaseId: 'ace731d1-c607-4aac-b09d-959e1bbb341f', certifiedSourceRecords: 12, reported: 12,
    distinctExceptionZips: 2, distinctExceptionZipsInHud: 1, hudReleaseKey: '2025-Q4',
    policyReleaseMatches: true, approvedExclusions: 11, unresolved: 1,
    ruleCountMismatches: [], certificationDecision: 'BLOCKED'});
  assert.equal((output[0] as any).hudStatus, 'NOT_IN_SELECTED_HUD_SNAPSHOT');
  assert.equal((output[11] as any).hudStatus, 'IN_SELECTED_HUD_SNAPSHOT');
  assert.equal((output[11] as any).sourceRecordSha256, 'a'.repeat(64));
});

test('report fails rather than treating an empty pinned release as a clean match', async () => {
  const client = {async query() {return {rows: [{record_count: '0'}]};}} as unknown as PoolClient;
  await assert.rejects(reportGeographyExceptions(client, policy, {releaseIds: {CBP: '0f522c9d-0592-4595-8962-5a3a53422e9e'}}, () => {}),
    /PINNED_RELEASE_HAS_NO_CERTIFIED_RECORDS:CENSUS_CBP/);
});
