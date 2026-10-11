# TCDS ZSL1 — External Evidence Acquisition, Provenance & Certification Authority

**Freeze package:** `TCDS_ZSL1_GREEN_TIER1_HARDENED_V2_1_FREEZE_FINAL`  
**Engine version:** `zsl1-v2.1.0`

## Mission

ZSL1 is the fail-closed acquisition authority for external evidence consumed by the ZSL Domain. It discovers a specific source release, retrieves the exact source artifact, fingerprints it, validates the source-specific schema, stores content-addressed raw records and run-specific membership, performs deterministic parser replay, reconciles the database snapshot, records immutable audit evidence, and only then permits runtime certification.

ZSL1 does **not** normalize ZIP/ZCTA geography, own PostGIS, select stores, rank deal areas, schedule R1D searches, or make BUY/NO-BUY decisions.

## Freeze-source coverage

1. U.S. Census Gazetteer — State / County / Place / ZCTA
2. HUD-USPS Crosswalk — ZIP→County / ZIP→CBSA with explicit YEAR + QUARTER
3. Census ACS 5-Year Data Profiles — State / County / Place / ZCTA
4. BEA Regional Price Parities — State / MSA
5. BTS Freight Analysis Framework 6 — governed Regional release

## CBP/ZBP forward candidate (not part of the V2.1 freeze)

The forward-only migration `003_zsl1_cbp_zbp_sources.sql` registers `CENSUS_CBP` and
`CENSUS_ZBP`. The new `cbp-state`, `cbp-county`, and `zbp-postal` ingest commands
accept the 2023 vintage only. They download and preserve Census's original state,
county, and ZIP-industry ZIP archives, then ingest only the exact six-digit
NAICS2017 codes listed in `config/cbp-zbp-selection.json`. Each selected record
retains its original CSV columns, archive member, and source row number, plus
the explicit field aliases needed by ZSL3.

State rows use the all-legal-forms total (`lfo=-`); county and ZIP detail rows
have no legal-form dimension. ZIP detail does not publish employment or annual
payroll in this bulk file, so those fields remain null rather than being
inferred. ZIP is an operational postal code, not a ZCTA. The source policy and
new contracts have version `2.1.1`; applied migration bytes 001-002 are unchanged.

This candidate must be resealed to a new package SHA, bootstrapped, and tested
against staging before any runtime certification. ZSL3's upstream binding
policy also needs an explicit update for mixed ZSL1 package identities; do
not weaken its exact-package or current-certification gates.

## V2.1 final-freeze hardening

- Corrected Census Gazetteer format handling: auto-detect tab or pipe-delimited national files.
- Corrected ZCTA authority contract: ZCTA requires `GEOID/GEOIDFQ/...`; it does not invent a `NAME` field.
- Corrected HUD-USPS raw API contract to the documented lowercase result fields (`zip`, `geoid`, ratio fields) and binds the response envelope to the requested year, quarter and crosswalk type.
- ACS variable metadata is fetched and cryptographically bound into schema-validation evidence for the exact vintage.
- BEA RPP validates exact year, line code, numeric RPP values and binds BEA Regional table metadata evidence.
- FAF6 uses a streaming CSV parser rather than `split(',')`, supports quoted fields, enforces ZIP-bomb controls, and requires core FAF dimensional columns plus `value_YEAR`/`tons_YEAR` measures.
- All HTTP downloads are streamed with bounded byte ceilings; artifact magic checks read only bounded header bytes.
- Artifact paths sanitize source, release and filename segments; persisted artifact SHA is reverified and file permissions hardened.
- Run-specific release-record membership prevents a retry or prior run from contaminating certification counts.
- Natural-key uniqueness is enforced per ingest run/artifact while content-addressed records remain globally de-duplicated.
- Source release identity becomes immutable once certified.
- Source policy, schema contract and certification policy content cannot be silently changed under the same version.
- Schema-validation rows are actually written and become mandatory certification evidence.
- Parser replay is executed against the exact downloaded artifact and must reproduce the ordered record digest.
- Reconciliation binds parsed count, run membership count, distinct record count and replay digest.
- Audit events are bound directly to the ingest run and are immutable.
- Certification is guarded both in TypeScript and PostgreSQL; a `CERTIFIED` insert is rejected unless the run is reconciled, schema validation passed and parser replay passed.
- Certification requires exact deployed package SHA, Git SHA, current source policy SHA, current schema-contract SHA, certification-policy SHA, full audit coverage and no secret leakage.
- Database TLS is verification-on by default; weakening certificate verification requires an explicit environment override.
- Downstream `zsl.certified_release_records` resolves only the effective certified ingest run for each release.

## Authority chain

```text
SOURCE
  ↓
SOURCE RELEASE
  ↓
DISCOVERY EVENT
  ↓
INGEST RUN
  ↓
PRIMARY ORIGINAL ARTIFACT
  ↓ SHA-256
SOURCE-SPECIFIC SCHEMA VALIDATION
  ↓
CONTENT-ADDRESSED RAW RECORDS
  ↓
RUN-SPECIFIC RELEASE MEMBERSHIP
  ↓
DETERMINISTIC PARSER REPLAY
  ↓
RECONCILIATION
  ↓
RUNTIME CERTIFICATION
  ↓
zsl.certified_release_records
  ↓
ZSL-B2
```

## Install

```bash
cp .env.example .env
# Set DATABASE_URL, API credentials where required,
# ZSL_GIT_SHA and the SHA-256 of the exact deployment ZIP in ZSL_PACKAGE_SHA256.

./scripts/install.sh
```

`install.sh` performs preflight, `npm ci --ignore-scripts`, strict TypeScript checking, tests, both PostgreSQL migrations, and governance-policy bootstrap.

## Runtime certification rule

A successful ingest is not enough. For each `ingestRunId`:

```bash
npm run certify -- <ingestRunId>
```

Only the latest certification event for that run can authorize downstream use. A later `REVOKED`/`SUPERSEDED` result invalidates the run.

## Status terminology

This ZIP may receive **10/10 GREEN TIER 1 STATIC IMPLEMENTATION / FREEZE CANDIDATE** after the static evidence passes.

It must **not** be called runtime `CERTIFIED`, `FREEZE APPROVED`, or `SAFE FOR ZSL-B2 DEPENDENCY` until this exact ZIP is installed against the real Supabase/PostgreSQL environment and the runtime certification gates pass with real Census/HUD/ACS/BEA/FAF6 source releases.

## BEA Regional RPP freeze rule

ZSL1 does not hard-code or assume an unverified BEA Regional RPP table/line. The operator must provide the exact table name and line code for the target BEA release, and the adapter verifies the table against live BEA Regional metadata before accepting the artifact.

```bash
npm run ingest -- bea-rpp-state <year> <metadata-verified-tableName> <lineCode>
npm run ingest -- bea-rpp-msa   <year> <metadata-verified-tableName> <lineCode>
```

## Connected supply-chain freeze gate

The source-review environment is offline from the npm registry. The included source freeze therefore requires `scripts/resolve-lock-connected.sh` on the approved connected build host before runtime certification. `scripts/install.sh` fails closed unless the complete transitive package lock passes `scripts/verify-lock.mjs`. See `docs/DEPENDENCY-FREEZE-GATE.md`.
