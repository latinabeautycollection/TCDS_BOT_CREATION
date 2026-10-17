import type {PoolClient} from 'pg';
import type {GeographyExclusion, GeographyExclusionRule, PolicyBundle} from '../core/types.js';
import {certifiedRows} from './facts.js';
import {canonicalLocationKey} from './geography.js';

export interface GeographyPreflight {
  checked: number;
  matched: number;
  exclusionsByRecordId: Map<string, GeographyExclusion|GeographyExclusionRule>;
}

function exclusionKey(sourceKey:string,vintage:string,releaseId:string,scope:string,geoid:string):string {
  return [sourceKey,vintage,releaseId,scope,geoid].join('|');
}

export async function auditSourceGeography(c:PoolClient,run:string,p:PolicyBundle):Promise<GeographyPreflight> {
  const canonical = new Set((await c.query<{canonical_key:string}>(
    `SELECT canonical_key FROM zsl.certified_canonical_locations`
  )).rows.map(row=>row.canonical_key));
  const exclusions = new Map<string,GeographyExclusion>();
  const rules=p.source.geographyExclusionRules??[];
  const ruleCounts=new Map<GeographyExclusionRule,number>(rules.map(rule=>[rule,0]));
  for(const item of p.source.geographyExclusions){
    const id=exclusionKey(item.sourceKey,item.sourceVintage,item.sourceReleaseId,item.geography,item.sourceGEOID);
    if(exclusions.has(id))throw new Error(`ZSL3_DUPLICATE_GEOGRAPHY_EXCLUSION:${id}`);
    exclusions.set(id,item);
  }
  for(const item of p.source.geographyCrosswalks){
    if(!canonical.has(item.targetCanonicalKey))throw new Error(`ZSL3_CROSSWALK_TARGET_NOT_CERTIFIED:${item.targetCanonicalKey}`);
  }
  const binds=(await c.query<any>(
    `SELECT * FROM zsl.zsl3_source_bindings WHERE build_run_id=$1 AND source_dataset IN('ACS','CBP','ZBP')`,[run]
  )).rows;
  let checked=0,matched=0;
  const seen=new Set<string>();
  const exclusionsByRecordId=new Map<string,GeographyExclusion|GeographyExclusionRule>();
  let unexpectedCount=0;
  const unexpected:Array<{sourceKey:string;scope:string;recordId:string;key:string|null}>=[];
  const noteUnexpected=(sourceKey:string,scope:string,recordId:string,key:string|null)=>{
    unexpectedCount++;
    if(unexpected.length<100)unexpected.push({sourceKey,scope,recordId,key});
  };
  for(const b of binds){
    const scope=b.source_dataset==='ZBP'?'POSTAL_CODE':b.source_geography;
    for(const raw of await certifiedRows(c,b)){
      checked++;
      const source={sourceKey:String(b.source_key),sourceVintage:String(b.source_vintage)};
      const matchedRules=rules.filter(rule=>rule.sourceKey===source.sourceKey&&rule.sourceVintage===source.sourceVintage&&rule.sourceReleaseId===String(b.release_id)&&rule.geography===scope&&String(raw.record?.[rule.field])===rule.value);
      if(matchedRules.length>1)throw new Error(`ZSL3_OVERLAPPING_GEOGRAPHY_RULES:${raw.record_id}`);
      if(matchedRules.length){
        const rule=matchedRules[0];ruleCounts.set(rule,(ruleCounts.get(rule)??0)+1);
        exclusionsByRecordId.set(raw.record_id,rule);continue;
      }
      const rawKey=canonicalLocationKey(scope,raw.record,source);
      const targetKey=canonicalLocationKey(scope,raw.record,source,p.source.geographyCrosswalks);
      const geoid=rawKey?.startsWith('US:PLACE:')?rawKey.slice('US:PLACE:'.length):'';
      const id=exclusionKey(source.sourceKey,source.sourceVintage,String(b.release_id),scope,geoid);
      const exception=exclusions.get(id);
      if(targetKey&&canonical.has(targetKey)){
        matched++;
        if(exception)noteUnexpected(source.sourceKey,scope,raw.record_id,targetKey);
      }else if(exception){
        if(seen.has(id)||exclusionsByRecordId.has(raw.record_id))throw new Error(`ZSL3_DUPLICATE_GEOGRAPHY_EXCEPTION_RECORD:${id}`);
        seen.add(id);
        exclusionsByRecordId.set(raw.record_id,exception);
      }else{
        noteUnexpected(source.sourceKey,scope,raw.record_id,targetKey);
      }
    }
  }
  const stale=[...exclusions.keys()].filter(id=>!seen.has(id));
  const wrongRuleCounts=rules.filter(rule=>ruleCounts.get(rule)!==rule.expectedCount).map(rule=>({sourceKey:rule.sourceKey,field:rule.field,value:rule.value,expected:rule.expectedCount,actual:ruleCounts.get(rule)}));
  if(unexpectedCount||stale.length||wrongRuleCounts.length){
    throw new Error(`ZSL3_GEOGRAPHY_PREFLIGHT_FAILED:${JSON.stringify({checked,matched,approvedExclusions:exclusionsByRecordId.size,unexpectedCount,unexpected,staleExclusions:stale,wrongRuleCounts})}`);
  }
  return {checked,matched,exclusionsByRecordId};
}
