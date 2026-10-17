import {randomUUID} from 'node:crypto';
import type {PoolClient} from 'pg';
import {sha256Canonical} from '../core/hash.js';

type FactRow = Record<string, unknown>;
export interface FactBatch { facts: FactRow[]; lineage: FactRow[]; }
export const FACT_BATCH_SIZE = 500;
export function createFactBatch(): FactBatch { return {facts: [], lineage: []}; }

/** Queue facts with caller-generated UUIDs so source facts and their lineage are inserted together. */
export function queueFact(batch: FactBatch, args: any): string {
 const factId=randomUUID();
 const doc={featureCode:args.featureCode,value:args.numericValue??args.textValue??null,unit:args.unit,sourceRole:args.sourceRole,sourceVintage:args.binding.source_vintage,geography:args.binding.source_geography,missingness:args.missingness??'PRESENT',suppressionFlag:args.suppressionFlag??null};
 batch.facts.push({factId,run:args.run,locationId:args.locationId,featureCode:args.featureCode,numericValue:args.numericValue??null,textValue:args.textValue??null,unit:args.unit,sourceRole:args.sourceRole,sourceBindingId:args.binding.source_binding_id,sourceRecordId:args.raw.record_id,sourceRecordSha256:args.raw.record_sha256,sourceVariableCode:args.sourceVariableCode??null,sourceVintage:args.binding.source_vintage,geographyScope:args.binding.source_geography,missingness:args.missingness??'PRESENT',suppressionFlag:args.suppressionFlag??null,factDocument:doc,factSha256:sha256Canonical(doc)});
 const lineage={factId,rawRecordId:args.raw.record_id,sourceBindingId:args.binding.source_binding_id,releaseId:args.binding.release_id,ingestRunId:args.binding.ingest_run_id,certificationRunId:args.binding.certification_run_id};
 batch.lineage.push({run:args.run,factId,sourceBindingId:args.binding.source_binding_id,sourceReleaseId:args.binding.release_id,ingestRunId:args.binding.ingest_run_id,certificationRunId:args.binding.certification_run_id,rawRecordId:args.raw.record_id,rawRecordSha256:args.raw.record_sha256,lineageDocument:lineage,lineageSha256:sha256Canonical(lineage)});
 return factId;
}

export async function flushFactBatch(c: PoolClient,batch: FactBatch): Promise<void> {
 if(batch.facts.length===0)return;
 await c.query(`INSERT INTO zsl.zsl3_source_facts(fact_id,build_run_id,location_id,feature_code,numeric_value,text_value,unit,evidence_class,source_role,source_binding_id,source_record_id,source_record_sha256,source_variable_code,source_vintage,geography_scope,source_geography_type,missingness_state,suppression_flag,fact_document,fact_sha256)
 SELECT fact_id::uuid,run::uuid,location_id::uuid,feature_code,numeric_value::numeric,text_value,unit,'SOURCE_FACT',source_role,source_binding_id::uuid,source_record_id::uuid,source_record_sha256,source_variable_code,source_vintage,geography_scope,geography_scope,missingness,suppression_flag,fact_document::jsonb,fact_sha256
 FROM jsonb_to_recordset($1::jsonb) AS x(fact_id text,run text,location_id text,feature_code text,numeric_value text,text_value text,unit text,source_role text,source_binding_id text,source_record_id text,source_record_sha256 text,source_variable_code text,source_vintage text,geography_scope text,missingness text,suppression_flag text,fact_document jsonb,fact_sha256 text)`,[JSON.stringify(batch.facts.map(f=>({fact_id:f.factId,run:f.run,location_id:f.locationId,feature_code:f.featureCode,numeric_value:f.numericValue,text_value:f.textValue,unit:f.unit,source_role:f.sourceRole,source_binding_id:f.sourceBindingId,source_record_id:f.sourceRecordId,source_record_sha256:f.sourceRecordSha256,source_variable_code:f.sourceVariableCode,source_vintage:f.sourceVintage,geography_scope:f.geographyScope,missingness:f.missingness,suppression_flag:f.suppressionFlag,fact_document:f.factDocument,fact_sha256:f.factSha256})))]);
 await c.query(`INSERT INTO zsl.zsl3_fact_lineage(build_run_id,fact_id,source_binding_id,source_release_id,ingest_run_id,certification_run_id,raw_record_id,raw_record_sha256,lineage_document,lineage_sha256)
 SELECT run::uuid,fact_id::uuid,source_binding_id::uuid,source_release_id::uuid,ingest_run_id::uuid,certification_run_id::uuid,raw_record_id::uuid,raw_record_sha256,lineage_document::jsonb,lineage_sha256
 FROM jsonb_to_recordset($1::jsonb) AS x(run text,fact_id text,source_binding_id text,source_release_id text,ingest_run_id text,certification_run_id text,raw_record_id text,raw_record_sha256 text,lineage_document jsonb,lineage_sha256 text)`,[JSON.stringify(batch.lineage.map(l=>({run:l.run,fact_id:l.factId,source_binding_id:l.sourceBindingId,source_release_id:l.sourceReleaseId,ingest_run_id:l.ingestRunId,certification_run_id:l.certificationRunId,raw_record_id:l.rawRecordId,raw_record_sha256:l.rawRecordSha256,lineage_document:l.lineageDocument,lineage_sha256:l.lineageSha256})))]);
 batch.facts.length=0;batch.lineage.length=0;
}

export async function insertFact(c:PoolClient,args:any):Promise<string>{const batch=createFactBatch();const factId=queueFact(batch,args);await flushFactBatch(c,batch);return factId}
export async function certifiedRows(c:PoolClient,b:any):Promise<any[]>{return(await c.query<any>(`SELECT rr.record_id::text,rr.record,rr.record_sha256 FROM zsl.release_record_memberships m JOIN zsl_raw.raw_records rr ON rr.record_id=m.record_id WHERE m.release_id=$1 AND m.ingest_run_id=$2 ORDER BY m.ordinal`,[b.release_id,b.ingest_run_id])).rows}
