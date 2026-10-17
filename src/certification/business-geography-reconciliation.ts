import type {PoolClient} from 'pg';
import type {PolicyBundle} from '../core/types.js';

export async function reconcileBusinessGeography(c:PoolClient,run:string,p:PolicyBundle){
  const rules=p.source.geographyExclusionRules??[];
  const bindings=(await c.query<any>(`SELECT * FROM zsl.zsl3_source_bindings WHERE build_run_id=$1 AND source_dataset IN('CBP','ZBP')`,[run])).rows;
  const warnings=(await c.query<any>(`SELECT evidence FROM zsl.zsl3_conflicts WHERE build_run_id=$1 AND conflict_code='BUSINESS_GEOGRAPHY_EXCLUDED' AND severity='WARN'`,[run])).rows;
  const warningByRecord=new Map<string,any>();
  let invalid=0,observed=0,factsOnExcluded=0;
  for(const row of warnings){const ev=row.evidence,id=String(ev.sourceRecordId);if(warningByRecord.has(id))invalid++;warningByRecord.set(id,ev)}
  for(const rule of rules){
    const binding=bindings.find((b:any)=>b.source_key===rule.sourceKey&&String(b.source_vintage)===rule.sourceVintage&&String(b.release_id)===rule.sourceReleaseId&&String(b.source_geography)===rule.geography);
    if(!binding){invalid++;continue}
    const rows=(await c.query<any>(`SELECT record_id::text AS record_id,record_sha256,record
      FROM zsl.certified_release_records WHERE release_id=$1 AND ingest_run_id=$2`,[binding.release_id,binding.ingest_run_id])).rows;
    const selected=rows.filter((r:any)=>String(r.record?.[rule.field])===rule.value);
    if(selected.length!==rule.expectedCount)invalid++;
    observed+=selected.length;
    for(const row of selected){
      const ev=warningByRecord.get(row.record_id);
      if(!ev||String(ev.sourceBindingId)!==String(binding.source_binding_id)||String(ev.sourceReleaseId)!==rule.sourceReleaseId||String(ev.sourceRecordSha256)!==String(row.record_sha256)||ev.sourceKey!==rule.sourceKey||ev.sourceVintage!==rule.sourceVintage||ev.geography!==rule.geography||ev.field!==rule.field||ev.value!==rule.value||ev.reasonCode!==rule.reasonCode)invalid++;
      const fact=(await c.query<any>(`SELECT 1 FROM zsl.zsl3_source_facts WHERE build_run_id=$1 AND source_binding_id=$2 AND source_record_id=$3 LIMIT 1`,[run,binding.source_binding_id,row.record_id])).rows;
      if(fact.length)factsOnExcluded++;
    }
  }
  if(warningByRecord.size!==observed)invalid+=Math.abs(warningByRecord.size-observed);
  return {ok:invalid===0&&factsOnExcluded===0,expected:rules.reduce((n,r)=>n+r.expectedCount,0),observed,warnings:warningByRecord.size,invalid,factsOnExcluded};
}
