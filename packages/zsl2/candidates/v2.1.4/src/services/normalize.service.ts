import type {PoolClient} from 'pg';
import {performance} from 'node:perf_hooks';
import {sha256Json} from '../core/hash.js';
import {asPgBigIntString,safeSmallInt} from '../core/exact.js';
import type {CertifiedRawRecord,CanonicalLocationInput,ExactRatios} from '../core/types.js';
import {normalizeGazetteer} from '../normalizers/gazetteer.js';
import {normalizeHudPostalLocation,normalizeHudRelationship,hudRatios} from '../normalizers/hud.js';
import {processGazetteerPageSetBased,processHudPageSetBased} from './setBasedNormalizer.js';
// V2.1.3 delegated set-based processor preserves HUD_CBSA_99999_OUTSIDE_CBSA policy and durable ORPHAN_PARENT CONFLICT lineage semantics.

export type PageSizes={defaultPageSize:number;sourcePageSizes?:Record<string,number>};
type Checkpoint={source_key:string;status:'PENDING'|'RUNNING'|'COMPLETE'|'FAILED';last_ordinal:string|null;last_record_id:string|null;page_number:string;records_processed:string;locations_processed:string;relationships_processed:string;lineage_processed:string};
type PageResult={records:number;locations:number;relationships:number;lineage:number;lastOrdinal:string;lastRecordId:string};
type HudStage={source_key:string;release_id:string;ingest_run_id:string;raw_record_id:string;record_sha256:string;parent_location_id:string;child_location_id:string;relationship_type:string;authority:string;ratios:ExactRatios;evidence_document:Record<string,unknown>;evidence_sha256:string};

const ZERO_UUID='00000000-0000-0000-0000-000000000000';
const positivePage=(n:number)=>Number.isInteger(n)&&n>0&&n<=10000?n:1000;
export const pageSizeFor=(source:string,cfg:PageSizes)=>positivePage(cfg.sourcePageSizes?.[source]??cfg.defaultPageSize);
const plus=(a:string,b:number)=>String(BigInt(a)+BigInt(b));

async function checkpointEvent(c:PoolClient,runId:string,source:string,page:string,eventType:string,delta:{records?:number;locations?:number;relationships?:number;lineage?:number}={},evidence:Record<string,unknown>={}){
 const h=sha256Json({runId,source,page,eventType,delta,evidence});
 await c.query(`insert into zsl.zsl2_checkpoint_events(normalization_run_id,source_key,page_number,event_type,last_ordinal,last_record_id,records_delta,locations_delta,relationships_delta,lineage_delta,evidence,evidence_sha256)
 select $1,$2,$3::bigint,$4,c.last_ordinal,c.last_record_id,$5,$6,$7,$8,$9::jsonb,$10 from zsl.zsl2_normalization_checkpoints c where c.normalization_run_id=$1 and c.source_key=$2`,
 [runId,source,page,eventType,delta.records??0,delta.locations??0,delta.relationships??0,delta.lineage??0,JSON.stringify(evidence),h]);
}

export async function recordPerformance(c:PoolClient,runId:string,source:string,page:string,operation:string,rows:number,durationMs:number,metadata:Record<string,unknown>={}){
 const evidence={runId,source,page,operation,rows,durationMs:Number(durationMs.toFixed(3)),metadata};
 await c.query(`insert into zsl.zsl2_performance_measurements(normalization_run_id,source_key,page_number,operation,rows_affected,duration_ms,statement_timeout_ms,metadata,evidence_sha256)
 values($1,$2,$3::bigint,$4,$5,$6,null,$7::jsonb,$8)`,[runId,source,page,operation,rows,durationMs,JSON.stringify(metadata),sha256Json(evidence)]);
}

export async function initializeCheckpoints(c:PoolClient,runId:string,sources:string[]){
 for(const source of sources){
  await c.query(`insert into zsl.zsl2_normalization_checkpoints(normalization_run_id,source_key,release_id,ingest_run_id,status)
    select b.normalization_run_id,b.source_key,b.release_id,b.ingest_run_id,'PENDING' from zsl.zsl2_source_bindings b
    where b.normalization_run_id=$1 and b.source_key=$2 on conflict(normalization_run_id,source_key) do nothing`,[runId,source]);
  await c.query(`select zsl.zsl2_capture_source_snapshot($1,$2)`,[runId,source]);
 }
}

async function checkpoint(c:PoolClient,runId:string,source:string):Promise<Checkpoint>{
 const q=await c.query(`select source_key,status,last_ordinal::text,last_record_id::text,page_number::text,records_processed::text,locations_processed::text,relationships_processed::text,lineage_processed::text
   from zsl.zsl2_normalization_checkpoints where normalization_run_id=$1 and source_key=$2 for update`,[runId,source]);
 if(q.rowCount!==1)throw new Error(`MISSING_CHECKPOINT:${source}`);
 const x=q.rows[0];
 return {source_key:String(x.source_key),status:x.status,last_ordinal:x.last_ordinal===null?null:asPgBigIntString(x.last_ordinal,'last_ordinal'),last_record_id:x.last_record_id?String(x.last_record_id):null,
   page_number:asPgBigIntString(x.page_number,'page_number'),records_processed:asPgBigIntString(x.records_processed,'records_processed'),locations_processed:asPgBigIntString(x.locations_processed,'locations_processed'),relationships_processed:asPgBigIntString(x.relationships_processed,'relationships_processed'),lineage_processed:asPgBigIntString(x.lineage_processed,'lineage_processed')};
}

async function boundCertifiedPage(c:PoolClient,runId:string,source:string,lastOrdinal:string|null,lastRecordId:string|null,pageSize:number):Promise<CertifiedRawRecord[]>{
 const q=await c.query(`select cr.source_key,cr.release_id::text,cr.release_key,cr.ingest_run_id::text,cr.artifact_id::text,cr.ordinal::text,cr.natural_key,cr.record_id::text,cr.record,cr.record_sha256
   from zsl.zsl2_source_bindings b join zsl.certified_release_records cr on cr.source_key=b.source_key and cr.release_id=b.release_id and cr.ingest_run_id=b.ingest_run_id
   where b.normalization_run_id=$1 and b.source_key=$2 and (cr.ordinal>$3::bigint or (cr.ordinal=$3::bigint and cr.record_id>$4::uuid))
   order by cr.ordinal,cr.record_id limit $5`,[runId,source,lastOrdinal??'-1',lastRecordId??ZERO_UUID,pageSize]);
 return q.rows as CertifiedRawRecord[];
}

async function upsertLocation(c:PoolClient,runId:string,x:CanonicalLocationInput):Promise<string>{
 const identityHash=sha256Json(x.identityDocument);
 const q=await c.query(`insert into zsl.locations(location_type,canonical_key,display_name,authority_status,identity_document,identity_sha256)
   values($1,$2,$3,$4,$5::jsonb,$6) on conflict(canonical_key) do update set canonical_key=excluded.canonical_key
   where zsl.locations.identity_sha256=excluded.identity_sha256 returning location_id::text`,[x.locationType,x.canonicalKey,x.displayName,x.authorityStatus,JSON.stringify(x.identityDocument),identityHash]);
 if(q.rowCount!==1)throw new Error(`IDENTITY_DRIFT:${x.canonicalKey}`);
 const id=String(q.rows[0].location_id); const rev={identity:x.identityDocument,attributes:x.revisionDocument,display_name:x.displayName,authority_status:x.authorityStatus,latitude:x.latitude??null,longitude:x.longitude??null};
 await c.query(`insert into zsl.zsl2_location_revisions(normalization_run_id,location_id,display_name,authority_status,latitude,longitude,point,source_key,source_release_id,source_ingest_run_id,source_record_sha256,revision_document,revision_sha256)
 values($1,$2,$3,$4,$5,$6,case when $5::numeric is null or $6::numeric is null then null else ST_SetSRID(ST_MakePoint($6,$5),4326)::geography end,$7,$8,$9,$10,$11::jsonb,$12)
 on conflict(normalization_run_id,location_id,source_key,source_record_sha256) do nothing`,[runId,id,x.displayName,x.authorityStatus,x.latitude??null,x.longitude??null,x.sourceKey,x.releaseId,x.ingestRunId,x.recordSha256,JSON.stringify(rev),sha256Json(rev)]);
 await c.query(`insert into zsl.zsl2_location_run_memberships(normalization_run_id,location_id,source_key,release_id,ingest_run_id,source_record_sha256) values($1,$2,$3,$4,$5,$6) on conflict do nothing`,[runId,id,x.sourceKey,x.releaseId,x.ingestRunId,x.recordSha256]);
 return id;
}

async function projectSubtype(c:PoolClient,x:CanonicalLocationInput,id:string){
 const d={...x.identityDocument,...x.revisionDocument} as Record<string,unknown>;
 if(x.locationType==='state')await c.query(`insert into zsl.states(location_id,state_fips,usps_code,official_name) values($1,$2,$3,$4) on conflict(location_id) do update set usps_code=excluded.usps_code,official_name=excluded.official_name where zsl.states.state_fips=excluded.state_fips`,[id,d.geoid,d.usps,d.name]);
 if(x.locationType==='county')await c.query(`insert into zsl.counties(location_id,county_fips,state_fips,official_name) values($1,$2,$3,$4) on conflict(location_id) do update set official_name=excluded.official_name where zsl.counties.county_fips=excluded.county_fips and zsl.counties.state_fips=excluded.state_fips`,[id,d.geoid,String(d.geoid).slice(0,2),d.name]);
 if(x.locationType==='place')await c.query(`insert into zsl.places(location_id,place_geoid,state_fips,official_name) values($1,$2,$3,$4) on conflict(location_id) do update set official_name=excluded.official_name where zsl.places.place_geoid=excluded.place_geoid and zsl.places.state_fips=excluded.state_fips`,[id,d.geoid,String(d.geoid).slice(0,2),d.name]);
 if(x.locationType==='zcta')await c.query(`insert into zsl.zctas(location_id,zcta5,geoidfq) values($1,$2,$3) on conflict(location_id) do update set geoidfq=excluded.geoidfq where zsl.zctas.zcta5=excluded.zcta5`,[id,d.geoid,d.geoidfq]);
 if(x.locationType==='postal_code')await c.query(`insert into zsl.postal_codes(location_id,postal_code,operational_authority_status) values($1,$2,'HUD_OBSERVED_PENDING_USPS') on conflict(location_id) do update set postal_code=excluded.postal_code where zsl.postal_codes.operational_authority_status in('HUD_OBSERVED_PENDING_USPS','PENDING_USPS_ZSL3')`,[id,d.postal_code]);
 if(x.locationType==='cbsa')await c.query(`insert into zsl.cbsa_metros(location_id,cbsa_code,official_name,name_authority_status) values($1,$2,null,'PENDING_CENSUS_OMB') on conflict(location_id) do update set cbsa_code=excluded.cbsa_code where zsl.cbsa_metros.official_name is null and zsl.cbsa_metros.name_authority_status='PENDING_CENSUS_OMB'`,[id,d.cbsa_code]);
}

async function relationshipOne(c:PoolClient,runId:string,parentId:string,childId:string,type:string,authority:string,r:CertifiedRawRecord,doc:Record<string,unknown>){
 const ev={...doc,authority,relationship_type:type,source_release_id:r.release_id};const h=sha256Json(ev);
 const existing=await c.query(`select relationship_id::text,evidence_sha256 from zsl.location_relationships where parent_location_id=$1 and child_location_id=$2 and relationship_type=$3 and authority=$4 and source_release_id=$5`,[parentId,childId,type,authority,r.release_id]);
 if(existing.rowCount===1 && String(existing.rows[0].evidence_sha256)!==h)throw new Error(`RELATIONSHIP_DRIFT:${type}:${parentId}:${childId}`);
 const q=existing.rowCount===1?existing:await c.query(`insert into zsl.location_relationships(parent_location_id,child_location_id,relationship_type,authority,source_release_id,source_ingest_run_id,source_record_sha256,evidence_document,evidence_sha256)
 values($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9) returning relationship_id::text`,[parentId,childId,type,authority,r.release_id,r.ingest_run_id,r.record_sha256,JSON.stringify(ev),h]);
 const relId=String(q.rows[0].relationship_id);
 await c.query(`insert into zsl.zsl2_relationship_run_memberships(normalization_run_id,relationship_id,source_key,release_id,ingest_run_id,source_record_sha256) values($1,$2,$3,$4,$5,$6) on conflict do nothing`,[runId,relId,r.source_key,r.release_id,r.ingest_run_id,r.record_sha256]);
 return relId;
}

async function lineageRow(c:PoolClient,run:string,r:CertifiedRawRecord,loc:string|null,rel:string|null,disp:string,reason:string|null=null){
 await c.query(`insert into zsl.zsl2_record_lineage(normalization_run_id,source_key,release_id,ingest_run_id,raw_record_id,raw_record_sha256,canonical_location_id,canonical_relationship_id,disposition,disposition_reason)
 values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) on conflict(normalization_run_id,source_key,raw_record_id) do nothing`,[run,r.source_key,r.release_id,r.ingest_run_id,r.record_id,r.record_sha256,loc,rel,disp,reason]);
}
async function conflict(c:PoolClient,run:string,code:string,severity:string,key:string,source:string,details:unknown){await c.query(`insert into zsl.zsl2_conflicts(normalization_run_id,conflict_code,severity,entity_key,source_key,details,details_sha256) values($1,$2,$3,$4,$5,$6::jsonb,$7)`,[run,code,severity,key,source,JSON.stringify(details),sha256Json(details)]);}

async function deriveGazetteerHierarchy(c:PoolClient,runId:string,x:CanonicalLocationInput,id:string,r:CertifiedRawRecord){
 const d=x.identityDocument as Record<string,unknown>;
 if(x.locationType==='state'){const q=await c.query(`select location_id::text from zsl.locations where canonical_key='US:NATIONAL'`);if(q.rowCount!==1)throw new Error('MISSING_NATIONAL_PARENT');await relationshipOne(c,runId,String(q.rows[0].location_id),id,'CONTAINS','CENSUS',r,{parent:'US:NATIONAL',child:x.canonicalKey});}
 if(x.locationType==='county'||x.locationType==='place'){const parentKey=`US:STATE:${String(d.geoid).slice(0,2)}`;const q=await c.query(`select location_id::text from zsl.locations where canonical_key=$1`,[parentKey]);if(q.rowCount!==1)throw new Error(`MISSING_STATE_PARENT:${parentKey}`);await relationshipOne(c,runId,String(q.rows[0].location_id),id,'STATE_OF','CENSUS',r,{parent:parentKey,child:x.canonicalKey});}
}

async function ensureHudStage(c:PoolClient){
 await c.query(`create temp table if not exists zsl2_hud_rel_stage(source_key text not null,release_id uuid not null,ingest_run_id uuid not null,raw_record_id uuid primary key,record_sha256 text not null,parent_location_id uuid not null,child_location_id uuid not null,relationship_type text not null,authority text not null,res_ratio numeric(12,9),bus_ratio numeric(12,9),oth_ratio numeric(12,9),tot_ratio numeric(12,9),evidence_document jsonb not null,evidence_sha256 text not null) on commit delete rows`);
}

async function flushHudRelationships(c:PoolClient,runId:string,rows:HudStage[]):Promise<number>{
 if(rows.length===0)return 0; await ensureHudStage(c);
 const cols={
  source_key:rows.map(r=>r.source_key),release_id:rows.map(r=>r.release_id),ingest_run_id:rows.map(r=>r.ingest_run_id),raw_record_id:rows.map(r=>r.raw_record_id),record_sha256:rows.map(r=>r.record_sha256),
  parent_location_id:rows.map(r=>r.parent_location_id),child_location_id:rows.map(r=>r.child_location_id),relationship_type:rows.map(r=>r.relationship_type),authority:rows.map(r=>r.authority),
  res_ratio:rows.map(r=>r.ratios.res),bus_ratio:rows.map(r=>r.ratios.bus),oth_ratio:rows.map(r=>r.ratios.oth),tot_ratio:rows.map(r=>r.ratios.tot),
  evidence_document:rows.map(r=>JSON.stringify(r.evidence_document)),evidence_sha256:rows.map(r=>r.evidence_sha256)
 };
 await c.query(`insert into zsl2_hud_rel_stage(source_key,release_id,ingest_run_id,raw_record_id,record_sha256,parent_location_id,child_location_id,relationship_type,authority,res_ratio,bus_ratio,oth_ratio,tot_ratio,evidence_document,evidence_sha256)
 select source_key,release_id::uuid,ingest_run_id::uuid,raw_record_id::uuid,record_sha256,parent_location_id::uuid,child_location_id::uuid,relationship_type,authority,res_ratio::numeric,bus_ratio::numeric,oth_ratio::numeric,tot_ratio::numeric,evidence_document::jsonb,evidence_sha256
 from unnest($1::text[],$2::text[],$3::text[],$4::text[],$5::text[],$6::text[],$7::text[],$8::text[],$9::text[],$10::text[],$11::text[],$12::text[],$13::text[],$14::text[],$15::text[])
 as x(source_key,release_id,ingest_run_id,raw_record_id,record_sha256,parent_location_id,child_location_id,relationship_type,authority,res_ratio,bus_ratio,oth_ratio,tot_ratio,evidence_document,evidence_sha256)`,
 [cols.source_key,cols.release_id,cols.ingest_run_id,cols.raw_record_id,cols.record_sha256,cols.parent_location_id,cols.child_location_id,cols.relationship_type,cols.authority,cols.res_ratio,cols.bus_ratio,cols.oth_ratio,cols.tot_ratio,cols.evidence_document,cols.evidence_sha256]);
 const drift=await c.query(`select count(*)::text n from zsl2_hud_rel_stage s join zsl.location_relationships r on r.parent_location_id=s.parent_location_id and r.child_location_id=s.child_location_id and r.relationship_type=s.relationship_type and r.authority=s.authority and r.source_release_id=s.release_id where r.evidence_sha256<>s.evidence_sha256`);
 if(BigInt(String(drift.rows[0].n))>0n){await conflict(c,runId,'RELATIONSHIP_DRIFT','FATAL','HUD_BATCH','HUD_USPS',{count:String(drift.rows[0].n)});throw new Error(`RELATIONSHIP_BATCH_DRIFT:${drift.rows[0].n}`);}
 await c.query(`insert into zsl.location_relationships(parent_location_id,child_location_id,relationship_type,authority,res_ratio,bus_ratio,oth_ratio,tot_ratio,source_release_id,source_ingest_run_id,source_record_sha256,evidence_document,evidence_sha256)
 select parent_location_id,child_location_id,relationship_type,authority,res_ratio,bus_ratio,oth_ratio,tot_ratio,release_id,ingest_run_id,record_sha256,evidence_document,evidence_sha256 from zsl2_hud_rel_stage
 on conflict(parent_location_id,child_location_id,relationship_type,authority,source_release_id) do nothing`);
 const bad=await c.query(`select count(*)::text n from (select s.raw_record_id,count(r.relationship_id) c from zsl2_hud_rel_stage s left join zsl.location_relationships r on r.parent_location_id=s.parent_location_id and r.child_location_id=s.child_location_id and r.relationship_type=s.relationship_type and r.authority=s.authority and r.source_release_id=s.release_id and r.evidence_sha256=s.evidence_sha256 group by s.raw_record_id having count(r.relationship_id)<>1) x`);
 if(BigInt(String(bad.rows[0].n))!==0n)throw new Error(`RELATIONSHIP_ONE_TO_ONE_FAILURE:${bad.rows[0].n}`);
 await c.query(`insert into zsl.zsl2_relationship_run_memberships(normalization_run_id,relationship_id,source_key,release_id,ingest_run_id,source_record_sha256)
 select $1,r.relationship_id,s.source_key,s.release_id,s.ingest_run_id,s.record_sha256 from zsl2_hud_rel_stage s join zsl.location_relationships r on r.parent_location_id=s.parent_location_id and r.child_location_id=s.child_location_id and r.relationship_type=s.relationship_type and r.authority=s.authority and r.source_release_id=s.release_id and r.evidence_sha256=s.evidence_sha256 on conflict do nothing`,[runId]);
 await c.query(`insert into zsl.zsl2_record_lineage(normalization_run_id,source_key,release_id,ingest_run_id,raw_record_id,raw_record_sha256,canonical_relationship_id,disposition)
 select $1,s.source_key,s.release_id,s.ingest_run_id,s.raw_record_id,s.record_sha256,r.relationship_id,'NORMALIZED_RELATIONSHIP' from zsl2_hud_rel_stage s join zsl.location_relationships r on r.parent_location_id=s.parent_location_id and r.child_location_id=s.child_location_id and r.relationship_type=s.relationship_type and r.authority=s.authority and r.source_release_id=s.release_id and r.evidence_sha256=s.evidence_sha256 on conflict(normalization_run_id,source_key,raw_record_id) do nothing`,[runId]);
 return rows.length;
}

async function processPage(c:PoolClient,runId:string,source:string,pageNumber:string,page:CertifiedRawRecord[]):Promise<PageResult>{
 const recorder=async(operation:string,rows:number,durationMs:number,metadata:Record<string,unknown>={})=>recordPerformance(c,runId,source,pageNumber,operation,rows,durationMs,metadata);
 const bulk=source.startsWith('CENSUS_GAZETTEER_')?await processGazetteerPageSetBased(c,runId,page,recorder):source.startsWith('HUD_USPS_')?await processHudPageSetBased(c,runId,source,page,recorder):(()=>{throw new Error(`UNSUPPORTED_SOURCE:${source}`)})();
 const last=page.at(-1);if(!last)throw new Error('EMPTY_PAGE');
 return {...bulk,lastOrdinal:asPgBigIntString(last.ordinal,'ordinal'),lastRecordId:String(last.record_id)};
}

async function markCheckpointFailure(c:PoolClient,runId:string,source:string,e:unknown){const msg=e instanceof Error?e.message:String(e);const code=(msg.split(':')[0]||'PAGE_FAILURE').slice(0,120);await c.query(`update zsl.zsl2_normalization_checkpoints set status='FAILED',error_code=$3,error_message=$4,checkpointed_at=now() where normalization_run_id=$1 and source_key=$2`,[runId,source,code,msg.slice(0,4000)]);}

export async function normalizeResumable(c:PoolClient,runId:string,sources:string[],cfg:PageSizes){
 await initializeCheckpoints(c,runId,sources);const totals={records:0n,locations:0n,relationships:0n,lineage:0n,pages:0n};
 for(const source of sources){
  let sourceSnapshotValidated=false;
  for(;;){
   try{
    await c.query('begin');await c.query(`select zsl.zsl2_lock_source_page($1,$2)`,[runId,source]);
    const cp=await checkpoint(c,runId,source);if(cp.status==='COMPLETE'){await c.query('commit');break;}
    if(!sourceSnapshotValidated){if(!(await c.query(`select zsl.zsl2_source_snapshot_still_valid($1,$2) valid`,[runId,source])).rows[0]?.valid)throw new Error(`SOURCE_SNAPSHOT_DRIFT:${source}`);sourceSnapshotValidated=true;}
    await c.query(`update zsl.zsl2_normalization_checkpoints set status='RUNNING',started_at=coalesce(started_at,now()),error_code=null,error_message=null where normalization_run_id=$1 and source_key=$2`,[runId,source]);
    const nextPage=plus(cp.page_number,1);await checkpointEvent(c,runId,source,nextPage,cp.status==='FAILED'?'RESUME':'PAGE_BEGIN');
    const fetchT0=performance.now();const page=await boundCertifiedPage(c,runId,source,cp.last_ordinal,cp.last_record_id,pageSizeFor(source,cfg));await recordPerformance(c,runId,source,nextPage,'PAGE_FETCH',page.length,performance.now()-fetchT0,{keyset:true,pageSize:pageSizeFor(source,cfg)});
    if(page.length===0){if(!(await c.query(`select zsl.zsl2_source_snapshot_still_valid($1,$2) valid`,[runId,source])).rows[0]?.valid)throw new Error(`SOURCE_SNAPSHOT_DRIFT_AT_COMPLETION:${source}`);const truth=await c.query(`select * from zsl.zsl2_checkpoint_truth($1,$2)`,[runId,source]);const tr=truth.rows[0];
      if(String(tr.records_processed)!==cp.records_processed||String(tr.lineage_processed)!==cp.lineage_processed)throw new Error(`CHECKPOINT_COUNTER_DRIFT:${source}`);
      const evidence={source,records:cp.records_processed,locations:cp.locations_processed,relationships:cp.relationships_processed,lineage:cp.lineage_processed,lastOrdinal:cp.last_ordinal,lastRecordId:cp.last_record_id,sourceSnapshotValid:true};
      await c.query(`update zsl.zsl2_normalization_checkpoints set status='COMPLETE',completed_at=now(),checkpointed_at=now(),checkpoint_evidence=$3::jsonb,checkpoint_sha256=$4 where normalization_run_id=$1 and source_key=$2`,[runId,source,JSON.stringify(evidence),sha256Json(evidence)]);await checkpointEvent(c,runId,source,cp.page_number,'SOURCE_COMPLETE',{},evidence);await c.query('commit');break;}
    const pageT0=performance.now();const r=await processPage(c,runId,source,nextPage,page);const duration=performance.now()-pageT0;const evidence={source,page:nextPage,lastOrdinal:r.lastOrdinal,lastRecordId:r.lastRecordId,pageRecords:r.records,pageLocations:r.locations,pageRelationships:r.relationships,pageLineage:r.lineage};
    await c.query(`update zsl.zsl2_normalization_checkpoints set status='RUNNING',last_ordinal=$3,last_record_id=$4,page_number=$5::bigint,records_processed=records_processed+$6,locations_processed=locations_processed+$7,relationships_processed=relationships_processed+$8,lineage_processed=lineage_processed+$9,checkpointed_at=now(),checkpoint_evidence=$10::jsonb,checkpoint_sha256=$11 where normalization_run_id=$1 and source_key=$2`,[runId,source,r.lastOrdinal,r.lastRecordId,nextPage,r.records,r.locations,r.relationships,r.lineage,JSON.stringify(evidence),sha256Json(evidence)]);
    await checkpointEvent(c,runId,source,nextPage,'PAGE_COMMIT',{records:r.records,locations:r.locations,relationships:r.relationships,lineage:r.lineage},evidence);await recordPerformance(c,runId,source,nextPage,'NORMALIZE_PAGE',r.records,duration,{pageSize:page.length});
    await c.query('commit');totals.records+=BigInt(r.records);totals.locations+=BigInt(r.locations);totals.relationships+=BigInt(r.relationships);totals.lineage+=BigInt(r.lineage);totals.pages++;
   }catch(e){try{await c.query('rollback')}catch{};try{await c.query('begin');await c.query(`select zsl.zsl2_lock_source_page($1,$2)`,[runId,source]);await markCheckpointFailure(c,runId,source,e);const cp=await checkpoint(c,runId,source);await checkpointEvent(c,runId,source,cp.page_number,'PAGE_FAIL',{}, {error:e instanceof Error?e.message:String(e)});await c.query('commit')}catch{try{await c.query('rollback')}catch{}}throw e;}
  }
 }
 return {records:totals.records.toString(),locations:totals.locations.toString(),relationships:totals.relationships.toString(),lineage:totals.lineage.toString(),pages:totals.pages.toString()};
}
