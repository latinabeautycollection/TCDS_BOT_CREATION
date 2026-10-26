import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

test('runtime catalogs have complete denominators and independent golden evidence starts pending',async()=>{
 const p=JSON.parse(await readFile('apps/zsl-tax-intelligence/catalog/state-source-execution-plan.json','utf8'));
 assert.equal(p.states.length,51);assert.equal(p.required_families,21);assert.equal(p.state_family_denominator,1071);for(const st of p.states)for(const f of st.families)assert.ok(['AUTOMATED','AUTOMATED_WITH_REGISTRATION','MANUAL_REVIEW_REQUIRED','UNRESOLVED'].includes(f.automation_mode));
 const g=JSON.parse(await readFile('apps/zsl-tax-intelligence/catalog/51-state-golden-cases.json','utf8'));
 assert.equal(g.cases.length,51);assert.equal(new Set(g.cases.map((x:any)=>x.state_code)).size,51);
 for(const c of g.cases){assert.equal(c.independent_evidence.review_status,'PENDING');assert.equal(c.expected.checkout_tax_cents,null)}
 const a=JSON.parse(await readFile('apps/zsl-tax-intelligence/catalog/high-risk-adversarial-cases.json','utf8'));assert.ok(a.cases.length>=20);
});

test('ten governed categories include cameras electronics and game consoles',async()=>{
 const t=JSON.parse(await readFile('apps/zsl-tax-intelligence/config/tax-product-taxonomy.json','utf8'));
 const names=Object.keys(t.businessCategories);assert.equal(names.length,10);
 for(const x of ['CAMERAS','ELECTRONICS','GAME_CONSOLES'])assert.ok(names.includes(x));
 assert.equal(t.businessCategories.ELECTRONICS.requires_refinement,true);
 const c=JSON.parse(await readFile('apps/zsl-tax-intelligence/catalog/10-category-tax-mapping-cases.json','utf8'));assert.equal(c.cases.length,10);
});

test('verified source catalog declares operational access mode',async()=>{
 const c=JSON.parse(await readFile('apps/zsl-tax-intelligence/catalog/verified-national-source-catalog.json','utf8'));
 for(const s of c.sources)assert.ok(['AUTOMATED','AUTOMATED_WITH_REGISTRATION','MANUAL_REVIEW_REQUIRED','UNRESOLVED'].includes(s.automation_mode));
});
