import type {PoolClient} from 'pg';
import type {PolicyBundle} from '../core/types.js';

export async function reconcileBusinessGeography(c:PoolClient,run:string,p:PolicyBundle){
  const rules=p.source.geographyExclusionRules??[];
  const bindings=(await c.query<any>(`SELECT * FROM zsl.zsl3_source_bindings WHERE build_run_id=$1 AND source_dataset IN('CBP','ZBP')`,[run])).rows;
  const warnings=(await c.query<any>(`SELECT evidence FROM zsl.zsl3_conflicts WHERE build_run_id=$1 AND conflict_code='BUSINESS_GEOGRAPHY_EXCLUDED' AND severity='WARN'`,[run])).rows;
  const warningByRecord=new Map<string,any>();
  let invalid=0,observed=0,factsOnExcluded=0;
  for(const row of warnings){const ev=row.evidence,id=String(ev.sourceRecordId);if(warningByRecord.has(id))invalid++;warningByRecord.set(id,ev)}
  for(const binding of bindings){
    const bindingRules=rules.filter(rule=>rule.sourceKey===binding.source_key&&rule.sourceVintage===String(binding.source_vintage)&&rule.sourceReleaseId===String(binding.release_id)&&rule.geography===String(binding.source_geography));
    if(bindingRules.length===0)continue;
    const field=binding.source_dataset==='ZBP'?'zip':'county';
    if(bindingRules.some(rule=>rule.field!==field)){invalid++;continue}
    const byValue=new Map(bindingRules.map(rule=>[rule.value,rule]));
    if(byValue.size!==bindingRules.length){invalid++;continue}
    const valueSql=field==='zip'
      ? "lpad(coalesce(record->>'ZIPCODE',record->>'zip code',record->>'zip'),5,'0')"
      : "lpad(coalesce(record->>'county',record->>'COUNTY'),3,'0')";
    const rows=(await c.query<any>(`SELECT record_id::text AS record_id,record_sha256,record
      FROM zsl.certified_release_records WHERE release_id=$1 AND ingest_run_id=$2
      AND ${valueSql} = ANY($3::text[])`,[binding.release_id,binding.ingest_run_id,[...byValue.keys()]])).rows;
    const counts=new Map<string,number>();
    for(const row of rows){
      const value=field==='zip'
        ? String(row.record?.ZIPCODE??row.record?.['zip code']??row.record?.zip??'').padStart(5,'0')
        : String(row.record?.county??row.record?.COUNTY??'').padStart(3,'0');
      counts.set(value,(counts.get(value)??0)+1);
      const rule=byValue.get(value);
      if(!rule){invalid++;continue}
      const ev=warningByRecord.get(row.record_id);
      if(!ev||String(ev.sourceBindingId)!==String(binding.source_binding_id)||String(ev.sourceReleaseId)!==rule.sourceReleaseId||String(ev.sourceRecordSha256)!==String(row.record_sha256)||ev.sourceKey!==rule.sourceKey||ev.sourceVintage!==rule.sourceVintage||ev.geography!==rule.geography||ev.field!==rule.field||ev.value!==rule.value||ev.reasonCode!==rule.reasonCode)invalid++;
    }
    for(const rule of bindingRules)if((counts.get(rule.value)??0)!==rule.expectedCount)invalid++;
    observed+=rows.length;
    if(rows.length){
      const facts=(await c.query<{source_record_id:string}>(`SELECT DISTINCT source_record_id::text AS source_record_id
        FROM zsl.zsl3_source_facts WHERE build_run_id=$1 AND source_binding_id=$2
        AND source_record_id=ANY($3::uuid[])`,[run,binding.source_binding_id,rows.map(row=>row.record_id)])).rows;
      factsOnExcluded+=facts.length;
    }
  }
  for(const rule of rules)if(!bindings.some((b:any)=>b.source_key===rule.sourceKey&&String(b.source_vintage)===rule.sourceVintage&&String(b.release_id)===rule.sourceReleaseId&&String(b.source_geography)===rule.geography))invalid++;
  if(warningByRecord.size!==observed)invalid+=Math.abs(warningByRecord.size-observed);
  return {ok:invalid===0&&factsOnExcluded===0,expected:rules.reduce((n,r)=>n+r.expectedCount,0),observed,warnings:warningByRecord.size,invalid,factsOnExcluded};
}
