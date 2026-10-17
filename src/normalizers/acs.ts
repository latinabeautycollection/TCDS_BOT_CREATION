import type {PoolClient} from 'pg';
import type {PolicyBundle} from '../core/types.js';
import {sha256Canonical} from '../core/hash.js';
import {certifiedRows,createFactBatch,FACT_BATCH_SIZE,flushFactBatch,queueFact} from './facts.js';
import {resolveLocations} from './geography.js';
import type {GeographyPreflight} from './geography-preflight.js';

function classify(raw:any):{value:number|null;state:string}{
 if(raw===null||raw===undefined||raw==='')return{value:null,state:'MISSING'};
 const s=String(raw).trim();
 if(['-666666666','-999999999','-888888888','N','(X)'].includes(s))return{value:null,state:'UNAVAILABLE'};
 const n=Number(s);return Number.isFinite(n)?{value:n,state:'PRESENT'}:{value:null,state:'INVALID_SOURCE_VALUE'};
}

export async function normalizeAcs(c:PoolClient,run:string,policy:PolicyBundle,preflight:GeographyPreflight):Promise<number>{
 let n=0;const batch=createFactBatch();
 const binds=(await c.query<any>(`SELECT * FROM zsl.zsl3_source_bindings WHERE build_run_id=$1 AND source_dataset='ACS'`,[run])).rows;
 for(const b of binds){
  const rows=await certifiedRows(c,b);
  const locations=await resolveLocations(c,b.source_geography,rows,{sourceKey:b.source_key,sourceVintage:b.source_vintage},policy.source.geographyCrosswalks);
  for(const raw of rows){
   const exclusion=preflight.exclusionsByRecordId.get(raw.record_id);
   if(exclusion){
    if(!('authorityCode' in exclusion))throw new Error('ZSL3_ACS_EXCEPTION_POLICY_INVALID');
    const evidence={sourceBindingId:b.source_binding_id,sourceReleaseId:b.release_id,sourceRecordId:raw.record_id,sourceRecordSha256:raw.record_sha256,sourceVintage:b.source_vintage,sourceGEOID:exclusion.sourceGEOID,authorityCode:exclusion.authorityCode,reasonCode:exclusion.reasonCode,geographyEvidence:policy.source.geographyEvidence};
    await c.query(`INSERT INTO zsl.zsl3_conflicts(build_run_id,severity,conflict_code,evidence,evidence_sha256) VALUES($1,'WARN','ACS_HISTORICAL_PLACE_NOT_CURRENT',$2::jsonb,$3)`,[run,JSON.stringify(evidence),sha256Canonical(evidence)]);
    continue;
   }
   const loc=locations.get(raw.record_id)??null;
   if(!loc)throw new Error(`ZSL3_ACS_UNRESOLVED_GEOGRAPHY:${b.source_geography}:${raw.record_id}`);
   for(const v of policy.feature.acsVariableBindings){
    const cv=classify(raw.record[v.variableCode]);
    queueFact(batch,{run,locationId:loc,featureCode:v.featureCode,numericValue:cv.value,unit:v.unit,sourceRole:'ACS',binding:b,raw,sourceVariableCode:v.variableCode,missingness:cv.state});
    n++;if(batch.facts.length>=FACT_BATCH_SIZE)await flushFactBatch(c,batch);
   }
  }
 }
 await flushFactBatch(c,batch);
 return n;
}
