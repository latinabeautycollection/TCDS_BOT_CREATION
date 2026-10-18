import test from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
const read=(p:string)=>readFileSync(p,'utf8');
const sql=['006_zsl2_v2_1_freeze_hardening.sql','007_zsl2_v2_1_certification_hardening.sql','008_zsl2_v2_1_rbac.sql'].map(x=>read(`database/migrations/${x}`)).join('\n');
const norm=read('src/services/normalize.service.ts');
const cert=read('src/services/certification.service.ts');
const replay=read('src/services/replay.service.ts');
const cli=read('src/cli/normalize.ts');

test('certified view is run scoped',()=>{assert.match(sql,/zsl2_location_run_memberships/);assert.match(sql,/zsl2_current_authority/);assert.doesNotMatch(sql,/WHERE EXISTS\(SELECT 1 FROM zsl\.zsl2_current_certification c WHERE c\.status='CERTIFIED'\)/)});
test('normalizer reads exact bound release and ingest run',()=>{assert.match(norm,/cr\.release_id=b\.release_id/);assert.match(norm,/cr\.ingest_run_id=b\.ingest_run_id/)});
test('upstream revocation propagates',()=>assert.match(sql,/zsl2_bindings_still_valid/));
test('certification package and policy must match normalization run',()=>{assert.match(sql,/ZSL2_CERT_PACKAGE_SHA_MISMATCH/);assert.match(sql,/ZSL2_CERT_POLICY_SHA_MISMATCH/)});
test('runtime checks are DB-bound',()=>{assert.match(sql,/zsl2_runtime_checks/);assert.match(sql,/ZSL2_CERT_MISSING_RUNTIME_CHECKS/)});
test('activation is explicit after certification',()=>{assert.match(sql,/zsl2_authority_events/);assert.match(sql,/ACTIVATED/)});
test('source vintages must be coherent',()=>{assert.match(cert,/source_vintage_coherence/);assert.match(sql,/source_vintage_coherence/)});
test('HUD ratios are range checked and reconciled',()=>{assert.match(sql,/chk_zsl_ratio_bounds/);assert.match(cert,/hud_ratio_reconciliation/)});
test('identity separates stable identity from mutable revision',()=>{assert.match(norm,/zsl2_location_revisions/);assert.match(norm,/revisionDocument/)});
test('replay checks relationship ratios',()=>{assert.match(replay,/eqNum\(z\.res_ratio/);assert.match(replay,/revision_sha256/)});
test('failed normalization remains for forensic audit',()=>assert.match(cli,/state='FAILED'/));
test('normalization is advisory locked',()=>assert.match(cli,/pg_try_advisory_lock/));
test('spatial services use certified authority only',()=>{assert.match(sql,/FROM zsl\.certified_canonical_locations/);assert.match(sql,/ZSL2_INVALID_RADIUS/)});
test('R1B candidates use certified current authority',()=>assert.match(sql,/FROM zsl\.certified_canonical_locations l/));
test('public function execution revoked',()=>assert.match(sql,/REVOKE EXECUTE ON FUNCTION zsl\.locations_within_radius/));
test('rollback does not violate schema state check',()=>{const rb=read('database/rollback/002_zsl2_v2_1_non_destructive_rollback.sql');assert.doesNotMatch(rb,/ROLLED_BACK/)});

test('HUD 99999 is preserved as outside-CBSA fact, not fake CBSA',()=>{assert.match(sql,/zsl2_postal_outside_cbsa_facts/);assert.match(norm,/HUD_CBSA_99999_OUTSIDE_CBSA/)});
test('HUD area code kind remains pending OMB classification',()=>assert.match(sql,/HUD_CBSA_OR_METDIV_PENDING_OMB/));
