import type {PoolClient} from 'pg';
import {sha256Canonical} from '../core/hash.js';
import type {PolicyBundle, GeographyScope} from '../core/types.js';
import {expectedZsl1PackageSha256} from '../upstream/zsl1-package-policy.js';

export function expectedReleaseMetadata(
  sourceKey: string,
  dataset: string,
  geography: GeographyScope
): Record<string, string> {
  if (sourceKey === 'CENSUS_ACS5_PROFILE' && dataset === 'ACS' &&
      ['STATE', 'COUNTY', 'PLACE', 'ZCTA'].includes(geography)) {
    return {dataset: 'acs/acs5/profile', geography};
  }
  if (sourceKey === 'BEA_REGIONAL_RPP' && dataset === 'BEA_RPP' &&
      (geography === 'STATE' || geography === 'MSA')) {
    return {
      dataset: 'Regional',
      geoFips: geography,
      tableName: geography === 'STATE' ? 'SARPP' : 'MARPP',
      lineCode: '1'
    };
  }
  if (sourceKey === 'CENSUS_CBP' && dataset === 'CBP' &&
      (geography === 'STATE' || geography === 'COUNTY')) {
    return {dataset: 'CBP', geography};
  }
  if (sourceKey === 'CENSUS_ZBP' && dataset === 'ZBP' && geography === 'POSTAL_CODE') {
    return {dataset: 'ZBP', geography};
  }
  throw new Error(`ZSL3_UNSUPPORTED_SOURCE_METADATA:${sourceKey}:${dataset}:${geography}`);
}

export async function bindSources(c: PoolClient, buildRunId: string, p: PolicyBundle): Promise<number> {
  let count = 0;
  for (const spec of p.source.requiredSources) {
    for (const geography of spec.geographies) {
      const metadata = expectedReleaseMetadata(spec.sourceKey, spec.dataset, geography);
      const q = await c.query<any>(`
        WITH latest_cert AS (
          SELECT DISTINCT ON (cr.ingest_run_id) cr.*
          FROM zsl.certification_runs cr
          ORDER BY cr.ingest_run_id, cr.created_at DESC, cr.certification_run_id DESC
        )
        SELECT s.source_key, sr.release_id, sr.release_key, sr.source_year, sr.source_quarter,
               sr.metadata, ir.ingest_run_id, ir.package_sha256, lc.certification_run_id
        FROM zsl.source_registry s
        JOIN zsl.source_releases sr ON sr.source_id = s.source_id
        JOIN zsl.ingest_runs ir ON ir.release_id = sr.release_id
        JOIN latest_cert lc ON lc.ingest_run_id = ir.ingest_run_id
        WHERE s.source_key = $1 AND ir.state = 'RECONCILED' AND lc.status = 'CERTIFIED'
          AND sr.metadata @> $2::jsonb
        ORDER BY sr.source_year DESC NULLS LAST, sr.source_quarter DESC NULLS LAST,
                 sr.release_id DESC
        LIMIT 1`, [spec.sourceKey, JSON.stringify(metadata)]);
      const r = q.rows[0];
      if (!r) {
        if (spec.required) {
          throw new Error(`ZSL3_REQUIRED_CERTIFIED_SOURCE_MISSING:${spec.sourceKey}:${geography}`);
        }
        continue;
      }
      const expected = expectedZsl1PackageSha256(p, spec.sourceKey);
      if (!expected || r.package_sha256 !== expected) {
        throw new Error(`ZSL3_ZSL1_PACKAGE_MISMATCH:${spec.sourceKey}:${geography}`);
      }
      const vintage = r.source_year
        ? `${r.source_year}${r.source_quarter ? '-Q' + r.source_quarter : ''}`
        : String(r.release_key);
      const doc = {
        sourceKey: spec.sourceKey,
        dataset: spec.dataset,
        geography,
        releaseMetadataContract: metadata,
        releaseRole: `${spec.dataset}_${geography}`,
        sourceVintage: vintage,
        releaseId: r.release_id,
        releaseKey: r.release_key,
        ingestRunId: r.ingest_run_id,
        certificationRunId: r.certification_run_id,
        packageSha256: r.package_sha256,
        expectedPackageSha256: expected
      };
      await c.query(`
        INSERT INTO zsl.zsl3_source_bindings(
          build_run_id, source_key, source_dataset, source_geography, release_role,
          source_vintage, source_year, source_quarter, release_id, release_key,
          ingest_run_id, certification_run_id, upstream_package_sha256,
          binding_document, binding_sha256
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14::jsonb,$15)`,
      [buildRunId, spec.sourceKey, spec.dataset, geography, doc.releaseRole, vintage,
        r.source_year, r.source_quarter, r.release_id, r.release_key, r.ingest_run_id,
        r.certification_run_id, r.package_sha256, JSON.stringify(doc), sha256Canonical(doc)]);
      count++;
    }
  }
  return count;
}
