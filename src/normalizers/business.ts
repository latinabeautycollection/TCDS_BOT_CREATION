import type {PoolClient} from 'pg';
import {certifiedRows,createFactBatch,FACT_BATCH_SIZE,flushFactBatch,queueFact} from './facts.js';
import {resolveLocations} from './geography.js';
import {sha256Canonical} from '../core/hash.js';
import type {GeographyPreflight} from './geography-preflight.js';

function readNum(v:any):number|null{if(v===null||v===undefined||v==='')return null;const n=Number(v);return Number.isFinite(n)?n:null}
function suppressed(flag:any,value:any):boolean{return value===null||value===undefined||value===''?String(flag??'').trim()!=='' : false}

type BusinessRow={factId:string;sourceVocab:string;code:string;estab:number|null;emp:number|null;pay:number|null;eFlag:string|null;empFlag:string|null;payFlag:string|null};
async function flushBusiness(c:PoolClient,rows:BusinessRow[]):Promise<void>{
 if(rows.length===0)return;
 await c.query(`INSERT INTO zsl.zsl3_business_activity_facts(fact_id,source_naics_vocabulary,normalized_naics_vocabulary,naics_code,establishment_count,employment,annual_payroll,establishment_flag,employment_flag,payroll_flag)
 SELECT fact_id::uuid,source_vocab,source_vocab,code,estab::bigint,emp::bigint,pay::numeric,e_flag,emp_flag,pay_flag
 FROM jsonb_to_recordset($1::jsonb) AS x(fact_id text,source_vocab text,code text,estab text,emp text,pay text,e_flag text,emp_flag text,pay_flag text)`,[JSON.stringify(rows.map(r=>({fact_id:r.factId,source_vocab:r.sourceVocab,code:r.code,estab:r.estab,emp:r.emp,pay:r.pay,e_flag:r.eFlag,emp_flag:r.empFlag,pay_flag:r.payFlag})))]);
 rows.length=0;
}

export async function normalizeBusiness(c:PoolClient,run:string,naicsPolicy:any,preflight:GeographyPreflight):Promise<number>{
 let n=0;const facts=createFactBatch();const business:BusinessRow[]=[];
 const binds=(await c.query<any>(`SELECT * FROM zsl.zsl3_source_bindings WHERE build_run_id=$1 AND source_dataset IN('CBP','ZBP')`,[run])).rows;
 for(const b of binds){
  const rows=await certifiedRows(c,b);const scope=b.source_dataset==='ZBP'?'POSTAL_CODE':b.source_geography;
  const locations=await resolveLocations(c,scope,rows);
  for(const raw of rows){
   const rule=preflight.exclusionsByRecordId.get(raw.record_id);
   if(rule){
    if(!('field' in rule))throw new Error('ZSL3_BUSINESS_EXCEPTION_POLICY_INVALID');
    const evidence={sourceBindingId:b.source_binding_id,sourceReleaseId:b.release_id,sourceRecordId:raw.record_id,sourceRecordSha256:raw.record_sha256,sourceVintage:b.source_vintage,sourceKey:b.source_key,geography:rule.geography,field:rule.field,value:rule.value,reasonCode:rule.reasonCode};
    await c.query(`INSERT INTO zsl.zsl3_conflicts(build_run_id,severity,conflict_code,evidence,evidence_sha256) VALUES($1,'WARN','BUSINESS_GEOGRAPHY_EXCLUDED',$2::jsonb,$3)`,[run,JSON.stringify(evidence),sha256Canonical(evidence)]);continue;
   }
   const loc=locations.get(raw.record_id)??null;if(!loc)throw new Error(`ZSL3_BUSINESS_UNRESOLVED_GEOGRAPHY:${scope}:${raw.record_id}`);
   const sourceVocab=raw.record.NAICS2017!=null?'NAICS2017':raw.record.NAICS2022!=null?'NAICS2022':null;if(!sourceVocab)throw new Error('ZSL3_NAICS_VOCABULARY_UNKNOWN');
   const code=String(raw.record[sourceVocab]??'');const groups=naicsPolicy.featureGroups.filter((g:any)=>g.targetVocabulary===sourceVocab&&g.codes.includes(code));if(groups.length===0)continue;
   const eFlag=raw.record.ESTAB_F??null,empFlag=raw.record.EMP_F??null,payFlag=raw.record.PAYANN_F??null;
   const estabSupp=suppressed(eFlag,raw.record.ESTAB),empSupp=suppressed(empFlag,raw.record.EMP),paySupp=suppressed(payFlag,raw.record.PAYANN);
   const estab=estabSupp?null:readNum(raw.record.ESTAB),emp=empSupp?null:readNum(raw.record.EMP),pay=paySupp?null:readNum(raw.record.PAYANN);
   for(const g of groups){
    const feature=g.groupCode==='ELECTRONICS_RETAIL'?'electronics_establishments':g.groupCode==='WAREHOUSING_STORAGE'?'warehouse_establishments':g.groupCode==='GENERAL_MERCHANDISE'?'retail_establishments':null;if(!feature)continue;
    const factId=queueFact(facts,{run,locationId:loc,featureCode:feature,numericValue:estab,unit:'ESTABLISHMENT',sourceRole:b.source_dataset,binding:b,raw,sourceVariableCode:code,missingness:estabSupp?'SUPPRESSED':estab===null?'MISSING':'PRESENT',suppressionFlag:eFlag});
    business.push({factId,sourceVocab,code,estab,emp,pay,eFlag,empFlag,payFlag});n++;
    if(facts.facts.length>=FACT_BATCH_SIZE){await flushFactBatch(c,facts);await flushBusiness(c,business)}
   }
  }
 }
 await flushFactBatch(c,facts);await flushBusiness(c,business);return n;
}
