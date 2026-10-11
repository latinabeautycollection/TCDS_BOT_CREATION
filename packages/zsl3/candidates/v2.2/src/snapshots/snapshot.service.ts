import type{PoolClient}from'pg';import{sha256Canonical}from'../core/hash.js';
import{freshness,aggregateFreshness}from'../freshness/freshness.js';import{confidence}from'../confidence/confidence.js';
import{computeCoverage}from'./coverage.service.js';import{sourceInputsForDerived}from'../replay/lineage.service.js';

async function sourceVintageSet(c:PoolClient,run:string,loc:string){
 const rows=(await c.query<any>(`SELECT DISTINCT b.release_role,f.source_vintage FROM zsl.zsl3_source_facts f JOIN zsl.zsl3_source_bindings b ON b.source_binding_id=f.source_binding_id WHERE f.build_run_id=$1 AND f.location_id=$2 ORDER BY b.release_role`,[run,loc])).rows;
 return Object.fromEntries(rows.map((x:any)=>[x.release_role,x.source_vintage]));
}
async function percentileCohort(c:PoolClient,run:string,d:any){
 const source=d.feature_code==='purchasing_power_index'?'real_median_household_income_index':d.feature_code==='retail_capacity_index'?'retail_density_per_100k':null;
 if(!source)return 20;
 const q=await c.query<any>(`SELECT count(*) n FROM zsl.zsl3_derived_features x JOIN zsl.locations l ON l.location_id=x.location_id JOIN zsl.locations t ON t.location_id=$3 WHERE x.build_run_id=$1 AND x.feature_code=$2 AND l.location_type=t.location_type AND x.source_vintage_set=$4::jsonb`,[run,source,d.location_id,JSON.stringify(d.source_vintage_set)]);
 return Number(q.rows[0]?.n??0);
}
export async function buildSnapshots(c:PoolClient,run:string,p:any,policySha:string):Promise<number>{
 const defs=(await c.query<any>(`SELECT count(*)::int n,encode(digest(string_agg(formula_sha256,'' ORDER BY feature_code),'sha256'),'hex') sha FROM zsl.zsl3_feature_definitions WHERE build_run_id=$1 AND enabled`,[run])).rows[0];
 const locations=(await c.query<any>(`SELECT DISTINCT x.location_id::text,l.location_type FROM(SELECT location_id FROM zsl.zsl3_source_facts WHERE build_run_id=$1 UNION SELECT location_id FROM zsl.zsl3_derived_features WHERE build_run_id=$1)x JOIN zsl.locations l ON l.location_id=x.location_id`,[run])).rows;
 let n=0;
 for(const l of locations){
  const lt=String(l.location_type).toUpperCase();
  const facts=(await c.query<any>(`SELECT fact_id::text id,feature_code,numeric_value,text_value,unit,missingness_state,source_role role,source_vintage vintage,fact_sha256 sha FROM zsl.zsl3_source_facts WHERE build_run_id=$1 AND location_id=$2 ORDER BY feature_code,fact_id`,[run,l.location_id])).rows;
  const derived=(await c.query<any>(`SELECT derived_feature_id::text id,feature_code,numeric_value,unit,derivation_scope,source_vintage_set,derivation_sha256 sha FROM zsl.zsl3_derived_features WHERE build_run_id=$1 AND location_id=$2 ORDER BY feature_code,derived_feature_id`,[run,l.location_id])).rows;
  const cov=await computeCoverage(c,run,l.location_id,lt,p);const vintages=await sourceVintageSet(c,run,l.location_id);
  if(Object.keys(vintages).length===0)throw new Error(`ZSL3_EMPTY_SOURCE_VINTAGE_SET:${l.location_id}`);
  const prepared:any[]=[];
  for(const f of facts){
    const fr=freshness(f.role,f.vintage,p.freshness);const miss=f.missingness_state;
    const conf=confidence({authority:1,freshness:fr.status,coverage:cov.sourceCoveragePct/100,missingness:miss,sampleSize:20,inherited:false,suppression:miss==='SUPPRESSED'},p.confidence);
    const vd={featureCode:f.feature_code,value:f.numeric_value??f.text_value??null,missingness:miss,freshness:fr,confidence:conf,coverage:cov,sourceObjectId:f.id,sourceVintage:f.vintage,sourceRole:f.role};
    prepared.push({kind:'SOURCE_FACT',obj:f,missingness:miss,freshness:fr,confidence:conf,doc:vd,valueSha:sha256Canonical(vd)});
  }
  for(const d of derived){
    const srcInputs=await sourceInputsForDerived(c,d.id);const fr=aggregateFreshness(srcInputs,p.freshness);
    const inherited=d.derivation_scope==='DERIVED_FROM_PARENT',sampleSize=await percentileCohort(c,run,d),miss=inherited?'DERIVED_FROM_PARENT':'PRESENT';
    const conf=confidence({authority:.95,freshness:fr.status,coverage:cov.overallFeatureCoveragePct/100,missingness:miss,sampleSize,inherited},p.confidence);
    const vd={featureCode:d.feature_code,value:d.numeric_value,missingness:miss,freshness:fr,confidence:conf,coverage:cov,sourceObjectId:d.id,sourceVintageSet:d.source_vintage_set,lineageInputs:srcInputs};
    prepared.push({kind:'DERIVED_FEATURE',obj:d,missingness:miss,freshness:fr,confidence:conf,doc:vd,valueSha:sha256Canonical(vd)});
  }
  const valueBindings=prepared.map(v=>({featureCode:v.obj.feature_code,evidenceClass:v.kind,sourceObjectId:v.obj.id,sourceObjectSha256:v.obj.sha,valueSha256:v.valueSha})).sort((a,b)=>`${a.featureCode}:${a.sourceObjectId}`.localeCompare(`${b.featureCode}:${b.sourceObjectId}`));
  const snapDoc={locationId:l.location_id,locationType:lt,sourceVintageSet:vintages,coverage:cov,formulaRegistrySha:defs.sha,policySha,values:valueBindings};
  const sq=await c.query<any>(`INSERT INTO zsl.zsl3_geographic_feature_snapshots(
    build_run_id,location_id,source_vintage_set,formula_registry_sha256,policy_sha256,
    expected_source_fact_count,actual_source_fact_count,expected_derived_feature_count,actual_derived_feature_count,
    required_sources_expected,required_sources_present,source_coverage_pct,source_fact_coverage_pct,derived_feature_coverage_pct,
    overall_feature_coverage_pct,location_coverage_pct,snapshot_document,snapshot_sha256)
    VALUES($1,$2,$3::jsonb,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17::jsonb,$18) RETURNING snapshot_id::text`,
    [run,l.location_id,JSON.stringify(vintages),defs.sha,policySha,cov.expectedSourceFactCount,cov.actualSourceFactCount,
     cov.expectedDerivedFeatureCount,cov.actualDerivedFeatureCount,cov.requiredSourcesExpected,cov.requiredSourcesPresent,
     cov.sourceCoveragePct,cov.sourceFactCoveragePct,cov.derivedFeatureCoveragePct,cov.overallFeatureCoveragePct,cov.locationCoveragePct,
     JSON.stringify(snapDoc),sha256Canonical(snapDoc)]);
  for(const v of prepared){
    const o=v.obj;
    await c.query(`INSERT INTO zsl.zsl3_geographic_feature_snapshot_values(snapshot_id,build_run_id,location_id,feature_code,numeric_value,text_value,unit,evidence_class,missingness_state,freshness_policy_id,age_days,freshness_status,confidence_score,confidence_label,source_object_id,source_object_sha256,value_document,value_sha256)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17::jsonb,$18)`,
      [sq.rows[0].snapshot_id,run,l.location_id,o.feature_code,o.numeric_value??null,o.text_value??null,o.unit,v.kind,v.missingness,p.freshness.version,v.freshness.ageDays,v.freshness.status,v.confidence.score,v.confidence.label,o.id,o.sha,JSON.stringify(v.doc),v.valueSha]);
  }
  n++;
 }
 return n;
}
