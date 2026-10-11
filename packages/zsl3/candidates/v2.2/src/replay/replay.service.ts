import type{PoolClient}from'pg';import{sha256Canonical}from'../core/hash.js';
import{freshness,aggregateFreshness}from'../freshness/freshness.js';import{confidence}from'../confidence/confidence.js';
import{computeCoverage}from'../snapshots/coverage.service.js';import{sourceInputsForDerived}from'./lineage.service.js';

async function percentileReplay(c:PoolClient,run:string,d:any,minimum:number){
 const source=d.feature_code==='purchasing_power_index'?'real_median_household_income_index':d.feature_code==='retail_capacity_index'?'retail_density_per_100k':null;
 if(!source)return{checked:false,ok:true,reason:'NOT_PERCENTILE'};
 const q=await c.query<any>(`WITH cohort AS(
  SELECT x.derived_feature_id,x.numeric_value,l.location_type,
         count(*) OVER() cohort_n,
         rank() OVER(ORDER BY x.numeric_value) rnk
  FROM zsl.zsl3_derived_features x JOIN zsl.locations l ON l.location_id=x.location_id
  JOIN zsl.locations t ON t.location_id=$3
  WHERE x.build_run_id=$1 AND x.feature_code=$2 AND l.location_type=t.location_type AND x.source_vintage_set=$4::jsonb
 ) SELECT cohort_n,rnk,numeric_value FROM cohort WHERE derived_feature_id=(SELECT input_derived_feature_id FROM zsl.zsl3_feature_lineage WHERE derived_feature_id=$5 AND input_type='DERIVED_FEATURE' LIMIT 1)`,
 [run,source,d.location_id,JSON.stringify(d.source_vintage_set),d.derived_feature_id]);
 const r=q.rows[0];if(!r)return{checked:true,ok:false,reason:'INPUT_NOT_IN_COHORT',cohort:0};
 const n=Number(r.cohort_n);if(n<minimum)return{checked:true,ok:false,reason:'COHORT_BELOW_MINIMUM',cohort:n};
 const calc=n===1?0:100*(Number(r.rnk)-1)/(n-1);
 return{checked:true,ok:Math.abs(calc-Number(d.numeric_value))<=1e-9,calc,stored:Number(d.numeric_value),cohort:n,rank:Number(r.rnk)};
}
async function sampleSize(c:PoolClient,run:string,d:any){
 const source=d.feature_code==='purchasing_power_index'?'real_median_household_income_index':d.feature_code==='retail_capacity_index'?'retail_density_per_100k':null;
 if(!source)return 20;
 const q=await c.query<any>(`SELECT count(*) n FROM zsl.zsl3_derived_features x JOIN zsl.locations l ON l.location_id=x.location_id JOIN zsl.locations t ON t.location_id=$3 WHERE x.build_run_id=$1 AND x.feature_code=$2 AND l.location_type=t.location_type AND x.source_vintage_set=$4::jsonb`,[run,source,d.location_id,JSON.stringify(d.source_vintage_set)]);
 return Number(q.rows[0]?.n??0);
}
export async function replayAll(c:PoolClient,run:string,p:any){
 let fChecked=0,fFailed=0,pChecked=0,pFailed=0;
 const derived=(await c.query<any>(`SELECT d.*,fd.formula_type,fd.input_feature_codes,fd.formula_sha256 FROM zsl.zsl3_derived_features d JOIN zsl.zsl3_feature_definitions fd ON fd.feature_definition_id=d.feature_definition_id WHERE d.build_run_id=$1 ORDER BY d.derived_feature_id`,[run])).rows;
 for(const d of derived){
   fChecked++;
   const ins=(await c.query<any>(`SELECT fl.input_type,fl.input_fact_id,fl.input_derived_feature_id,fl.input_sha256,sf.feature_code sf_code,sf.numeric_value sf_val,df.feature_code df_code,df.numeric_value df_val
    FROM zsl.zsl3_feature_lineage fl LEFT JOIN zsl.zsl3_source_facts sf ON sf.fact_id=fl.input_fact_id LEFT JOIN zsl.zsl3_derived_features df ON df.derived_feature_id=fl.input_derived_feature_id
    WHERE fl.derived_feature_id=$1 ORDER BY fl.feature_lineage_id`,[d.derived_feature_id])).rows;
   const vals=Object.fromEntries(ins.map((x:any)=>[x.sf_code??x.df_code,Number(x.sf_val??x.df_val)]));
   let calc:number|null=null;
   if(d.formula_type==='PERCENT_RANK'){
     const pr=await percentileReplay(c,run,d,p.feature.minimumPercentileCohortSize);pChecked++;if(!pr.ok)pFailed++;calc=pr.ok?Number(pr.calc):null;
   }else{
     switch(d.feature_code){
       case'real_median_household_income_index':calc=vals.median_household_income&&vals.regional_price_parity?vals.median_household_income/(vals.regional_price_parity/100):null;break;
       case'retail_density_per_100k':calc=vals.population?100000*vals.retail_establishments/vals.population:null;break;
       case'electronics_density_per_100k':calc=vals.population?100000*vals.electronics_establishments/vals.population:null;break;
       case'warehouse_density_per_100k':calc=vals.population?100000*vals.warehouse_establishments/vals.population:null;break;
       case'economic_pressure_index':calc=Number.isFinite(vals.purchasing_power_index)&&Number.isFinite(vals.poverty_pct)?.5*(100-vals.purchasing_power_index)+.5*vals.poverty_pct:null;break;
     }
   }
   if(calc==null||Math.abs(calc-Number(d.numeric_value))>1e-9)fFailed++;
 }
 let snapChecked=0,snapFailed=0,freshChecked=0,freshFailed=0,confChecked=0,confFailed=0,missChecked=0,missFailed=0;
 const snaps=(await c.query<any>(`SELECT s.*,upper(l.location_type) location_type FROM zsl.zsl3_geographic_feature_snapshots s JOIN zsl.locations l ON l.location_id=s.location_id WHERE s.build_run_id=$1`,[run])).rows;
 for(const s of snaps){
   const vals=(await c.query<any>(`SELECT * FROM zsl.zsl3_geographic_feature_snapshot_values WHERE snapshot_id=$1 ORDER BY feature_code,source_object_id`,[s.snapshot_id])).rows;
   const cov=await computeCoverage(c,run,String(s.location_id),String(s.location_type),p);
   const bindings=vals.map((v:any)=>({featureCode:v.feature_code,evidenceClass:v.evidence_class,sourceObjectId:String(v.source_object_id),sourceObjectSha256:v.source_object_sha256,valueSha256:v.value_sha256})).sort((a:any,b:any)=>`${a.featureCode}:${a.sourceObjectId}`.localeCompare(`${b.featureCode}:${b.sourceObjectId}`));
   const snapDoc={locationId:String(s.location_id),locationType:String(s.location_type),sourceVintageSet:s.source_vintage_set,coverage:cov,formulaRegistrySha:s.formula_registry_sha256,policySha:s.policy_sha256,values:bindings};
   snapChecked++;if(sha256Canonical(snapDoc)!==s.snapshot_sha256)snapFailed++;
   for(const v of vals){
     let fr:any,miss:string,sample=20,inherited=false,authority=1,coverage=cov.sourceCoveragePct/100;
     if(v.evidence_class==='SOURCE_FACT'){
       const sf=(await c.query<any>(`SELECT source_role,source_vintage,missingness_state FROM zsl.zsl3_source_facts WHERE fact_id=$1`,[v.source_object_id])).rows[0];
       if(!sf){freshChecked++;freshFailed++;confChecked++;confFailed++;missChecked++;missFailed++;continue}
       fr=freshness(sf.source_role,sf.source_vintage,p.freshness);miss=sf.missingness_state;
     }else{
       const d=(await c.query<any>(`SELECT * FROM zsl.zsl3_derived_features WHERE derived_feature_id=$1`,[v.source_object_id])).rows[0];
       if(!d){freshChecked++;freshFailed++;confChecked++;confFailed++;missChecked++;missFailed++;continue}
       fr=aggregateFreshness(await sourceInputsForDerived(c,String(v.source_object_id)),p.freshness);
       inherited=d.derivation_scope==='DERIVED_FROM_PARENT';miss=inherited?'DERIVED_FROM_PARENT':'PRESENT';authority=.95;coverage=cov.overallFeatureCoveragePct/100;sample=await sampleSize(c,run,d);
     }
     freshChecked++;if(fr.status!==v.freshness_status||Number(fr.ageDays??-1)!==Number(v.age_days??-1))freshFailed++;
     missChecked++;if(miss!==v.missingness_state)missFailed++;
     const cf=confidence({authority,freshness:fr.status,coverage,missingness:miss,sampleSize:sample,inherited,suppression:miss==='SUPPRESSED'},p.confidence);
     confChecked++;if(Math.abs(cf.score-Number(v.confidence_score))>1e-9||cf.label!==v.confidence_label)confFailed++;
     if(sha256Canonical(v.value_document)!==v.value_sha256)snapFailed++;
   }
 }
 return{
  feature:{checked:fChecked,failed:fFailed},
  percentile:{checked:pChecked,failed:pFailed},
  snapshot:{checked:snapChecked,failed:snapFailed},
  freshness:{checked:freshChecked,failed:freshFailed},
  confidence:{checked:confChecked,failed:confFailed},
  missingness:{checked:missChecked,failed:missFailed}
 };
}
