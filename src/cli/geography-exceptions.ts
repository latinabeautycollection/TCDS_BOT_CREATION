import {pool} from '../repositories/db.js';
import {loadPolicies} from '../core/config.js';
import {reportGeographyExceptions} from '../normalizers/geography-exceptions.js';

const policy = loadPolicies().source;
const releaseIds = {CBP: process.env.ZSL3_CBP_RELEASE_ID, ZBP: process.env.ZSL3_ZBP_RELEASE_ID};
if (!releaseIds.CBP && !releaseIds.ZBP) throw new Error('ZSL3_SOURCE_RELEASE_ID_REQUIRED');
for (const releaseId of Object.values(releaseIds))
  if (releaseId && !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(releaseId))
    throw new Error('ZSL3_SOURCE_RELEASE_ID_INVALID');
const client = await pool.connect();
try {
  await client.query('BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY');
  await reportGeographyExceptions(client, policy,
    {releaseIds, hudReleaseKey: process.env.ZSL3_HUD_RELEASE_KEY},
    line => process.stdout.write(`${JSON.stringify(line)}\n`));
  await client.query('COMMIT');
} catch (error) {
  await client.query('ROLLBACK');
  throw error;
} finally {
  client.release();
  await pool.end();
}
