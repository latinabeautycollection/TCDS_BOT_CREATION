import type{PoolClient}from'pg';
import{sha256Canonical}from'../core/hash.js';import{expectedZsl1PackageSha256}from'../upstream/zsl1-package-policy.js';

export async function validateBuild(c:PoolClient,run:string,p:any){
 const failures:any[]=[];const details:any={};
 const binds=(await c.query<any>(`SELECT * FROM zsl.zsl3_source_bindings WHERE build_run_id=$1`,[run])).rows;
 details.bindingCount=binds.length;if(!binds.length)failures.push({code:'NO_SOURCE_BINDINGS'});
 const expected=p.source.requiredSources.flatMap((s:any)=>s.geographies.filter((g:string)=>s.required).map((g:string)=>`${s.dataset}_${g}`));
 const roles=new Set(binds.map((b:any)=>b.release_role));const missing=expected.filter((x:string)=>!roles.has(x));details.missingBindings=missing;if(missing.length)failures.push({code:'MISSING_REQUIRED_BINDINGS',missing});
 const packageChecks=binds.map((b:any)=>{const expected=expectedZsl1PackageSha256(p,b.source_key);return{sourceKey:b.source_key,actual:b.upstream_package_sha256,expected,match:!!expected&&b.upstream_package_sha256===expected}});const badPkg=packageChecks.filter((x:any)=>!x.match);details.zsl1PackageChecks=packageChecks;details.zsl1PackageMismatches=badPkg.length;if(badPkg.length)failures.push({code:'ZSL1_PACKAGE_MISMATCH',count:badPkg.length,details:badPkg});
 const md=Number((await c.query<any>(`SELECT count(*) n FROM zsl.zsl3_acs_variable_metadata WHERE build_run_id=$1`,[run])).rows[0]?.n??0);
 const acsBinds=binds.filter((b:any)=>b.source_dataset==='ACS').length;const expectedMd=acsBinds*p.feature.acsVariableBindings.length;details.acsMetadata={actual:md,expected:expectedMd};if(md!==expectedMd)failures.push({code:'ACS_METADATA_INCOMPLETE',actual:md,expected:expectedMd});
 const dup=Number((await c.query<any>(`SELECT count(*) n FROM(SELECT location_id,feature_code,source_binding_id,COALESCE(source_variable_code,''),source_record_id,count(*) c FROM zsl.zsl3_source_facts WHERE build_run_id=$1 GROUP BY 1,2,3,4,5 HAVING count(*)>1)x`,[run])).rows[0]?.n??0);details.duplicateFacts=dup;if(dup)failures.push({code:'DUPLICATE_FACTS',count:dup});
 const orphan=Number((await c.query<any>(`SELECT count(*) n FROM zsl.zsl3_source_facts f LEFT JOIN zsl.certified_canonical_locations l ON l.location_id=f.location_id WHERE f.build_run_id=$1 AND l.location_id IS NULL`,[run])).rows[0]?.n??0);details.orphanFacts=orphan;if(orphan)failures.push({code:'ORPHAN_LOCATION_FACTS',count:orphan});
 const zbpBad=Number((await c.query<any>(`SELECT count(*) n FROM zsl.zsl3_source_facts WHERE build_run_id=$1 AND source_role='ZBP' AND geography_scope<>'POSTAL_CODE'`,[run])).rows[0]?.n??0);details.zbpWrongGrain=zbpBad;if(zbpBad)failures.push({code:'ZIP_ZCTA_COLLISION',count:zbpBad});
 const fatal=Number((await c.query<any>(`SELECT count(*) n FROM zsl.zsl3_conflicts WHERE build_run_id=$1 AND severity='FATAL'`,[run])).rows[0]?.n??0);details.fatalConflicts=fatal;if(fatal)failures.push({code:'FATAL_CONFLICTS',count:fatal});
 const by:Record<string,Set<string>>={};for(const b of binds){(by[b.source_dataset]??=new Set()).add(String(b.source_year??b.source_vintage))}
 if((by.ACS?.size??0)>1)failures.push({code:'ACS_VINTAGE_INCOHERENT',years:[...(by.ACS??new Set())]});
 if((by.BEA_RPP?.size??0)>1)failures.push({code:'BEA_VINTAGE_INCOHERENT',years:[...(by.BEA_RPP??new Set())]});
 details.failures=failures;const ev={run,details,validatedAt:new Date().toISOString()};
 if(failures.length){await c.query(`INSERT INTO zsl.zsl3_conflicts(build_run_id,severity,conflict_code,evidence,evidence_sha256) VALUES($1,'FATAL','BUILD_VALIDATION_FAILED',$2::jsonb,$3)`,[run,JSON.stringify(ev),sha256Canonical(ev)]);throw new Error(`ZSL3_BUILD_VALIDATION_FAILED:${failures.map(x=>x.code).join(',')}`)}
 return ev;
}
