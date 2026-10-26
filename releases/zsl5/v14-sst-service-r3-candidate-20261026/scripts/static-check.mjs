import {readFile,readdir} from 'node:fs/promises';import {join} from 'node:path';
const root=new URL('../',import.meta.url);
async function walk(p){const es=await readdir(p,{withFileTypes:true});let a=[];for(const e of es){const q=join(p,e.name);if(e.isDirectory()&&e.name!=='node_modules'&&e.name!=='dist')a=a.concat(await walk(q));else if(e.isFile())a.push(q)}return a}
const files=await walk(root.pathname);const sql=(await Promise.all(files.filter(x=>x.endsWith('.sql')).map(x=>readFile(x,'utf8')))).join('\n').toLowerCase();
for(const domain of ['retail.','arb.','pqp.','cax.']){const bad=new RegExp('\\b(insert|update|delete|alter|create|drop)\\s+(table\\s+)?'+domain.replace('.','\\.')).test(sql);if(bad)throw new Error('CROSS_DOMAIN_MUTATION:'+domain)}

const candidateUsers=[];for(const f of files.filter(x=>x.endsWith('.ts')&&(x.includes('/apps/')||x.includes('/repo-overlay/apps/')))){const t=await readFile(f,'utf8');if(t.includes('quoteTaxV14Candidate'))candidateUsers.push(f.replace(root.pathname,''));}
const allowed=['apps/zsl-tax-intelligence/src/zsl5/tax-quote-v14.service.ts','apps/zsl-tax-intelligence/src/runtime/run-national-tax-certification.ts','apps/zsl-tax-intelligence/src/runtime/run-adversarial-certification.ts','apps/zsl-tax-intelligence/src/runtime/run-replay-certification.ts'];
for(const f of candidateUsers){const x=f.startsWith('repo-overlay/')?f.slice('repo-overlay/'.length):f;if(!allowed.includes(x))throw new Error('CANDIDATE_QUOTE_LEAK:'+f);}

const fam=JSON.parse(await readFile(new URL('../apps/zsl-tax-intelligence/config/required-tax-families.json',import.meta.url),'utf8'));if(fam.families.length!==21||fam.jurisdictions.length!==51||fam.state_family_denominator!==1071)throw new Error('DENOMINATOR_INVALID');
const tax=JSON.parse(await readFile(new URL('../apps/zsl-tax-intelligence/config/tax-product-taxonomy.json',import.meta.url),'utf8'));const cats=Object.keys(tax.businessCategories);if(cats.length!==10||!['CAMERAS','ELECTRONICS','GAME_CONSOLES'].every(x=>cats.includes(x)))throw new Error('TAX_CATEGORY_SCOPE_INVALID');if(tax.businessCategories.ELECTRONICS.requires_refinement!==true)throw new Error('ELECTRONICS_MUST_REQUIRE_REFINEMENT');
const src=JSON.parse(await readFile(new URL('../apps/zsl-tax-intelligence/catalog/verified-national-source-catalog.json',import.meta.url),'utf8'));for(const x of src.sources)if(!x.automation_mode)throw new Error('SOURCE_AUTOMATION_MODE_MISSING:'+x.source_key);
console.log(JSON.stringify({status:'PASS',files:files.length,families:21,jurisdictions:51,denominator:1071,categories:10},null,2));
