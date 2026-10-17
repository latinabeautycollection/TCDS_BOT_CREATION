import type {PoolClient} from 'pg';
import type {GeographyExclusion, PolicyBundle} from '../core/types.js';

export interface AcsGeographyReconciliation {
  ok:boolean;
  checked:number;
  matched:number;
  excluded:number;
  missing:number;
  partial:number;
  invalidExceptions:number;
  expectedExclusions:number;
  failures:Array<{bindingId:string;code:string;count:number}>;
}

function policyKey(item:GeographyExclusion):string {
  return [item.sourceKey,item.sourceVintage,item.sourceReleaseId,item.geography,item.sourceGEOID,item.authorityCode,item.reasonCode].join('|');
}

export async function reconcileAcsGeography(c:PoolClient,run:string,p:PolicyBundle):Promise<AcsGeographyReconciliation> {
  const binds=(await c.query<any>(`SELECT * FROM zsl.zsl3_source_bindings WHERE build_run_id=$1 AND source_dataset='ACS'`,[run])).rows;
  const permitted=new Set(p.source.geographyExclusions.map(policyKey));
  const used=new Set<string>();
  const failures:Array<{bindingId:string;code:string;count:number}>=[];
  let checked=0,matched=0,excluded=0,missing=0,partial=0,invalidExceptions=0;
  for(const b of binds){
    const source=(await c.query<{record_id:string;record_sha256:string}>(
      `SELECT m.record_id::text,r.record_sha256 FROM zsl.release_record_memberships m
       JOIN zsl_raw.raw_records r ON r.record_id=m.record_id
       WHERE m.release_id=$1 AND m.ingest_run_id=$2`,
      [b.release_id,b.ingest_run_id]
    )).rows;
    const facts=(await c.query<{source_record_id:string;facts:string}>(
      `SELECT source_record_id::text,count(*)::text facts FROM zsl.zsl3_source_facts
       WHERE build_run_id=$1 AND source_binding_id=$2 GROUP BY source_record_id`,[run,b.source_binding_id]
    )).rows;
    const exceptionRows=(await c.query<{evidence:any}>(
      `SELECT evidence FROM zsl.zsl3_conflicts WHERE build_run_id=$1
       AND conflict_code='ACS_HISTORICAL_PLACE_NOT_CURRENT' AND evidence->>'sourceBindingId'=$2`,
      [run,b.source_binding_id]
    )).rows;
    const sourceHashes=new Map(source.map(row=>[row.record_id,row.record_sha256]));
    const sourceIds=new Set(sourceHashes.keys());
    const factCounts=new Map(facts.map(row=>[row.source_record_id,Number(row.facts)]));
    const exceptionIds=new Set<string>();
    const bindingId=String(b.source_binding_id);
    const before={missing,partial,invalidExceptions};
    checked+=sourceIds.size;
    if(sourceIds.size!==source.length)partial+=source.length-sourceIds.size;
    for(const row of exceptionRows){
      const ev=row.evidence;
      const item:GeographyExclusion={sourceKey:String(b.source_key),sourceVintage:String(ev.sourceVintage),
        sourceReleaseId:String(ev.sourceReleaseId),geography:b.source_geography,
        sourceGEOID:String(ev.sourceGEOID),authorityCode:String(ev.authorityCode),reasonCode:ev.reasonCode};
      const key=policyKey(item),id=String(ev.sourceRecordId);
      if(!sourceIds.has(id)||exceptionIds.has(id)||!permitted.has(key)||used.has(key)
        ||String(ev.sourceReleaseId)!==String(b.release_id)
        ||String(ev.sourceVintage)!==String(b.source_vintage)
        ||String(ev.sourceBindingId)!==bindingId
        ||String(ev.sourceRecordSha256)!==sourceHashes.get(id)
        ||String(ev.geographyEvidence?.source2024Sha256)!==p.source.geographyEvidence.source2024Sha256
        ||String(ev.geographyEvidence?.target2026Sha256)!==p.source.geographyEvidence.target2026Sha256){
        invalidExceptions++;
      }else{
        exceptionIds.add(id);used.add(key);
      }
    }
    excluded+=exceptionIds.size;
    for(const id of sourceIds){
      const count=factCounts.get(id)??0;
      if(exceptionIds.has(id)){
        if(count)partial++;
      }else if(count===p.feature.acsVariableBindings.length){
        matched++;
      }else if(count===0){
        missing++;
      }else{
        partial++;
      }
    }
    for(const id of factCounts.keys())if(!sourceIds.has(id))partial++;
    const count=(missing-before.missing)+(partial-before.partial)+(invalidExceptions-before.invalidExceptions);
    if(count)failures.push({bindingId,code:'ACS_RECORD_RECONCILIATION',count});
  }
  const stale=permitted.size-used.size;
  if(stale)failures.push({bindingId:'POLICY',code:'UNOBSERVED_EXCLUSIONS',count:stale});
  return {ok:failures.length===0,checked,matched,excluded,missing,partial,invalidExceptions,
    expectedExclusions:permitted.size,failures};
}
