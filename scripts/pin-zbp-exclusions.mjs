import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';

const expectedHash = 'c114e4a3df618b2dee7fd351a27ea81efe51b4266b74d6ff50ed9c4bc0a95d03';
const releaseId = 'ace731d1-c607-4aac-b09d-959e1bbb341f';
const hudSnapshot = '2025-Q4';
const reportPath = process.argv[2];
if (!reportPath) throw new Error('Usage: node scripts/pin-zbp-exclusions.mjs REPORT.csv');

const report = fs.readFileSync(reportPath);
const actualHash = createHash('sha256').update(report).digest('hex');
if (actualHash !== expectedHash) throw new Error(`REPORT_SHA256_MISMATCH:${actualHash}`);
const lines = report.toString('utf8').trimEnd().split(/\r?\n/);
if (lines.shift() !== 'zbp_release_id,hud_snapshot,zip,source_record_count,reason')
  throw new Error('REPORT_HEADER_MISMATCH');

const seen = new Set();
let recordCount = 0;
const rules = lines.map(line => {
  const [release, snapshot, zip, count, reason, extra] = line.split(',');
  const expectedCount = Number(count);
  if (extra !== undefined || release !== releaseId || snapshot !== hudSnapshot ||
      !/^\d{5}$/.test(zip) || !Number.isSafeInteger(expectedCount) || expectedCount <= 0 ||
      reason !== 'NOT_IN_HUD_2025_Q4' || seen.has(zip))
    throw new Error(`INVALID_REPORT_ROW:${line}`);
  seen.add(zip);
  recordCount += expectedCount;
  return {sourceKey: 'CENSUS_ZBP', sourceVintage: '2023', sourceReleaseId: releaseId,
    geography: 'POSTAL_CODE', field: 'zip', value: zip, expectedCount,
    reasonCode: 'NOT_IN_HUD_2025_Q4'};
});
if (rules.length !== 331 || recordCount !== 2030)
  throw new Error(`REPORT_TOTAL_MISMATCH:${rules.length}:${recordCount}`);

const policyPath = path.resolve('config/source-policy.json');
const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
const cbpRule = policy.geographyExclusionRules.find(rule => rule.sourceKey === 'CENSUS_CBP');
if (!cbpRule || cbpRule.value !== '999') throw new Error('CBP_AGGREGATE_RULE_MISSING');
cbpRule.sourceReleaseId = 'f55687ff-46de-48bb-8875-d39b8032e6d0';
cbpRule.expectedCount = 10525;
policy.geographyExclusionRules = [
  ...policy.geographyExclusionRules.filter(rule => rule.sourceKey !== 'CENSUS_ZBP'),
  ...rules,
];
policy.geographyExclusionEvidence = {
  cbpCounty2023: {releaseId: cbpRule.sourceReleaseId, countyValue: '999',
    sourceRecordCount: 10525, distinctStates: 50, disposition: 'NON_COUNTY_AGGREGATE'},
  zbpHud2025Q4: {releaseId, hudSnapshot, csvSha256: expectedHash,
    distinctZipCount: rules.length, sourceRecordCount: recordCount,
    disposition: 'EXCLUDE_FROM_ZSL3_FACTS_PENDING_SOURCE_REVIEW'},
};
fs.writeFileSync(policyPath, `${JSON.stringify(policy, null, 2)}\n`);
const evidencePath = path.resolve('evidence/ZBP_HUD_2025Q4_NONMATCHES.csv');
fs.copyFileSync(reportPath, evidencePath);
console.log(`PINNED_ZBP_EXCLUSIONS zips=${rules.length} records=${recordCount} report_sha256=${expectedHash}`);
