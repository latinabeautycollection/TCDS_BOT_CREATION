import type{PoolClient}from'pg';import{certifiedRows,insertFact}from'./facts.js';import{resolveLocation}from'./geography.js';
function classify(raw:any):{value:number|null;state:string}{
 if(raw===null||raw===undefined||raw==='')return{value:null,state:'MISSING'};
 const s=String(raw).trim();
 if(['-666666666','-999999999','-888888888','N','(X)'].includes(s))return{value:null,state:'UNAVAILABLE'};
 const n=Number(s);if(!Number.isFinite(n))return{value:null,state:'INVALID_SOURCE_VALUE'};
 return{value:n,state:'PRESENT'};
}
export async function normalizeAcs(c:PoolClient,run:string,policy:any):Promise<number>{
 let n=0;const binds=(await c.query<any>(`SELECT * FROM zsl.zsl3_source_bindings WHERE build_run_id=$1 AND source_dataset='ACS'`,[run])).rows;
 for(const b of binds){for(const raw of await certifiedRows(c,b)){
   const loc=await resolveLocation(c,b.source_geography,raw.record);
   if(!loc)throw new Error(`ZSL3_ACS_UNRESOLVED_GEOGRAPHY:${b.source_geography}:${raw.record_id}`);
   for(const v of policy.acsVariableBindings){
     const cv=classify(raw.record[v.variableCode]);
     await insertFact(c,{run,locationId:loc,featureCode:v.featureCode,numericValue:cv.value,unit:v.unit,sourceRole:'ACS',
       binding:b,raw,sourceVariableCode:v.variableCode,missingness:cv.state});
     n++;
   }
 }}
 return n;
}
