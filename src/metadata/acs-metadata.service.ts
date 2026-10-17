import type{PoolClient}from'pg';
import{sha256Canonical}from'../core/hash.js';

function metadataMap(v:any):Record<string,any>{
 if(Array.isArray(v)){const o:Record<string,any>={};for(const x of v){const k=String(x?.name??x?.variable??x?.variableCode??'');if(k)o[k]=x}return o}
 if(v&&typeof v==='object')return v;
 return{};
}
export async function populateAcsMetadata(c:PoolClient,run:string,featurePolicy:any):Promise<number>{
 const binds=(await c.query<any>(`SELECT * FROM zsl.zsl3_source_bindings WHERE build_run_id=$1 AND source_dataset='ACS'`,[run])).rows;
 let n=0;
 for(const b of binds){
   const q=await c.query<any>(`
     SELECT schema_validation_run_id::text,artifact_id::text,validation_document
     FROM zsl.schema_validation_runs
     WHERE ingest_run_id=$1
     ORDER BY created_at DESC,schema_validation_run_id DESC
     LIMIT 1`,[b.ingest_run_id]);
   const vr=q.rows[0];
   if(!vr)throw new Error(`ZSL3_ACS_METADATA_AUTHORITY_MISSING:${b.source_geography}:${b.ingest_run_id}`);
   const evidence=vr.validation_document?.evidence??{};
   const vm=evidence.variableMetadata;
   if(!vm)throw new Error(`ZSL3_ACS_METADATA_AUTHORITY_MISSING:${b.source_geography}:variableMetadata`);
   const computedMetaSha=sha256Canonical(vm);
   if(evidence.variableMetadataSha256&&String(evidence.variableMetadataSha256)!==computedMetaSha)
     throw new Error(`ZSL3_ACS_METADATA_SHA_MISMATCH:${b.source_geography}`);
   const validationDocSha=sha256Canonical(vr.validation_document);
   const mm=metadataMap(vm);
   for(const v of featurePolicy.acsVariableBindings){
     const md=mm[v.variableCode];
     if(!md)throw new Error(`ZSL3_ACS_METADATA_MISSING:${v.variableCode}:${b.source_geography}`);
     const label=String(md.label??md.Label??'');
     const concept=String(md.concept??md.Concept??'');
     const predicateType=String(md.predicateType??md.predicate_type??md.predicateTypeGroup??'');
     if(v.expectedLabelContains&&!label.toLowerCase().includes(String(v.expectedLabelContains).toLowerCase()))
       throw new Error(`ZSL3_ACS_METADATA_LABEL_DRIFT:${v.variableCode}:${label}`);
     if(v.expectedConceptContains&&!concept.toLowerCase().includes(String(v.expectedConceptContains).toLowerCase()))
       throw new Error(`ZSL3_ACS_METADATA_CONCEPT_DRIFT:${v.variableCode}:${concept}`);
     if(v.expectedPredicateType&&predicateType!==String(v.expectedPredicateType))
       throw new Error(`ZSL3_ACS_METADATA_PREDICATE_DRIFT:${v.variableCode}:${predicateType}`);
     const doc={
       dataset:b.source_dataset,vintage:b.source_vintage,group:md.group??null,variableCode:v.variableCode,
       label,concept:concept||null,predicateType:predicateType||null,unit:v.unit,
       geographyApplicability:[b.source_geography],sourceReleaseId:b.release_id,ingestRunId:b.ingest_run_id,
       artifactId:vr.artifact_id,schemaValidationRunId:vr.schema_validation_run_id,
       zsl1VariableMetadataSha256:computedMetaSha,zsl1ValidationDocumentSha256:validationDocSha
     };
     await c.query(`INSERT INTO zsl.zsl3_acs_variable_metadata(
       build_run_id,source_binding_id,dataset,vintage,variable_group,variable_code,label,concept,predicate_type,unit,
       geography_applicability,metadata_document,metadata_sha256,source_release_id,ingest_run_id,artifact_id,
       schema_validation_run_id,zsl1_validation_document_sha256)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12::jsonb,$13,$14,$15,$16,$17,$18)`,
       [run,b.source_binding_id,b.source_dataset,b.source_vintage,md.group??null,v.variableCode,label,concept||null,
        predicateType||null,v.unit,[b.source_geography],JSON.stringify(doc),sha256Canonical(doc),b.release_id,
        b.ingest_run_id,vr.artifact_id,vr.schema_validation_run_id,validationDocSha]);
     n++;
   }
 }
 return n;
}
