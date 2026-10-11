import type{PoolClient}from'pg';
export interface CoverageResult{
 requiredSourcesExpected:number;requiredSourcesPresent:number;sourceCoveragePct:number;
 expectedSourceFactCount:number;actualSourceFactCount:number;sourceFactCoveragePct:number;
 expectedDerivedFeatureCount:number;actualDerivedFeatureCount:number;derivedFeatureCoveragePct:number;
 overallFeatureCoveragePct:number;locationCoveragePct:number;expectedLocations:number;actualLocations:number;
}
function pct(n:number,d:number){return d===0?100:Math.max(0,Math.min(100,100*n/d))}
export function expectedSourceFeatures(locationType:string,featurePolicy:any):string[]{
 const acs=featurePolicy.acsVariableBindings.map((x:any)=>x.featureCode);
 if(locationType==='STATE')return[...acs,'regional_price_parity','retail_establishments','electronics_establishments','warehouse_establishments'];
 if(locationType==='COUNTY')return[...acs,'retail_establishments','electronics_establishments','warehouse_establishments'];
 if(locationType==='PLACE'||locationType==='ZCTA')return acs;
 if(locationType==='POSTAL_CODE')return['retail_establishments','electronics_establishments','warehouse_establishments'];
 return[];
}
export function expectedDerivedFeatures(locationType:string,featurePolicy:any,sourceExpected:string[]):string[]{
 const available=new Set(sourceExpected),out:string[]=[];let changed=true;
 while(changed){changed=false;for(const d of featurePolicy.derivedDefinitions){
   if(available.has(d.featureCode))continue;
   if(d.requires.every((x:string)=>available.has(x))){available.add(d.featureCode);out.push(d.featureCode);changed=true}
 }}
 return out;
}
export async function computeCoverage(c:PoolClient,run:string,locationId:string,locationType:string,p:any):Promise<CoverageResult>{
 const ce=p.source.coverageExpectations?.[locationType]??{requiredSources:[],optionalSources:[]};
 const presentRoles=(await c.query<any>(`SELECT DISTINCT b.release_role FROM zsl.zsl3_source_facts f JOIN zsl.zsl3_source_bindings b ON b.source_binding_id=f.source_binding_id WHERE f.build_run_id=$1 AND f.location_id=$2`,[run,locationId])).rows.map((x:any)=>x.release_role);
 const req=ce.requiredSources??[],reqPresent=req.filter((x:string)=>presentRoles.includes(x)).length;
 const expectedFacts=expectedSourceFeatures(locationType,p.feature),expectedDerived=expectedDerivedFeatures(locationType,p.feature,expectedFacts);
 const factRows=(await c.query<any>(`SELECT DISTINCT feature_code FROM zsl.zsl3_source_facts WHERE build_run_id=$1 AND location_id=$2 AND missingness_state='PRESENT'`,[run,locationId])).rows.map((x:any)=>x.feature_code);
 const derRows=(await c.query<any>(`SELECT DISTINCT feature_code FROM zsl.zsl3_derived_features WHERE build_run_id=$1 AND location_id=$2`,[run,locationId])).rows.map((x:any)=>x.feature_code);
 const af=expectedFacts.filter(x=>factRows.includes(x)).length,ad=expectedDerived.filter(x=>derRows.includes(x)).length;
 const expectedLoc=Number((await c.query<any>(`SELECT count(*) n FROM zsl.certified_canonical_locations WHERE location_type=$1`,[locationType])).rows[0]?.n??0);
 const actualLoc=Number((await c.query<any>(`SELECT count(DISTINCT f.location_id) n FROM(SELECT location_id FROM zsl.zsl3_source_facts WHERE build_run_id=$1 UNION SELECT location_id FROM zsl.zsl3_derived_features WHERE build_run_id=$1)f JOIN zsl.locations l ON l.location_id=f.location_id WHERE l.location_type=$2`,[run,locationType])).rows[0]?.n??0);
 return{
  requiredSourcesExpected:req.length,requiredSourcesPresent:reqPresent,sourceCoveragePct:pct(reqPresent,req.length),
  expectedSourceFactCount:expectedFacts.length,actualSourceFactCount:af,sourceFactCoveragePct:pct(af,expectedFacts.length),
  expectedDerivedFeatureCount:expectedDerived.length,actualDerivedFeatureCount:ad,derivedFeatureCoveragePct:pct(ad,expectedDerived.length),
  overallFeatureCoveragePct:pct(af+ad,expectedFacts.length+expectedDerived.length),
  locationCoveragePct:pct(actualLoc,expectedLoc),expectedLocations:expectedLoc,actualLocations:actualLoc
 };
}
