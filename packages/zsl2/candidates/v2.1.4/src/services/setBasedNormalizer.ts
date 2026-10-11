import type {PoolClient, QueryResult} from 'pg';
import {performance} from 'node:perf_hooks';
import {sha256Json} from '../core/hash.js';
import type {CertifiedRawRecord,CanonicalLocationInput,ExactRatios} from '../core/types.js';
import {normalizeGazetteer} from '../normalizers/gazetteer.js';
import {normalizeHudPostalLocation,normalizeHudRelationship,hudRatios} from '../normalizers/hud.js';

export type OperationRecorder=(operation:string,rows:number,durationMs:number,metadata?:Record<string,unknown>)=>Promise<void>;
export type BulkPageResult={records:number;locations:number;relationships:number;lineage:number};

type LocationStage={x:CanonicalLocationInput;identitySha:string;revisionDoc:Record<string,unknown>;revisionSha:string};
type RelationshipStage={
 source_key:string;release_id:string;ingest_run_id:string;raw_record_id:string;record_sha256:string;
 parent_key:string;child_key:string;relationship_type:string;authority:string;ratios:ExactRatios;
 evidence_document:Record<string,unknown>;evidence_sha256:string;
};

async function timed<T extends QueryResult>(c:PoolClient,record:OperationRecorder,operation:string,rows:number,sql:string,params:unknown[]=[]):Promise<T>{
 const t0=performance.now();
 const q=await c.query(sql,params) as T;
 await record(operation,rows,performance.now()-t0,{rowCount:q.rowCount??0});
 return q;
}

async function ensureLocationStage(c:PoolClient){
 await c.query(`create temp table if not exists zsl2_location_stage(
   location_type text not null, canonical_key text not null, display_name text, authority_status text not null,
   identity_document jsonb not null, identity_sha256 text not null, revision_document jsonb not null, revision_sha256 text not null,
   latitude numeric(9,6), longitude numeric(9,6), source_key text not null, release_id uuid not null, ingest_run_id uuid not null,
   raw_record_id uuid not null, record_sha256 text not null
 ) on commit delete rows`);
}

async function bulkLocations(c:PoolClient,runId:string,inputs:CanonicalLocationInput[],record:OperationRecorder):Promise<Map<string,string>>{
 const map=new Map<string,string>(); if(inputs.length===0)return map;
 await ensureLocationStage(c); await c.query(`truncate zsl2_location_stage`);
 const rows:LocationStage[]=inputs.map(x=>{const identitySha=sha256Json(x.identityDocument);const revisionDoc={identity:x.identityDocument,attributes:x.revisionDocument,display_name:x.displayName,authority_status:x.authorityStatus,latitude:x.latitude??null,longitude:x.longitude??null};return{x,identitySha,revisionDoc,revisionSha:sha256Json(revisionDoc)}});
 const cols={
  location_type:rows.map(r=>r.x.locationType),canonical_key:rows.map(r=>r.x.canonicalKey),display_name:rows.map(r=>r.x.displayName),authority_status:rows.map(r=>r.x.authorityStatus),
  identity_document:rows.map(r=>JSON.stringify(r.x.identityDocument)),identity_sha256:rows.map(r=>r.identitySha),revision_document:rows.map(r=>JSON.stringify(r.revisionDoc)),revision_sha256:rows.map(r=>r.revisionSha),
  latitude:rows.map(r=>r.x.latitude==null?null:String(r.x.latitude)),longitude:rows.map(r=>r.x.longitude==null?null:String(r.x.longitude)),source_key:rows.map(r=>r.x.sourceKey),release_id:rows.map(r=>r.x.releaseId),
  ingest_run_id:rows.map(r=>r.x.ingestRunId),raw_record_id:rows.map(r=>r.x.recordId),record_sha256:rows.map(r=>r.x.recordSha256)
 };
 await timed(c,record,'LOCATION_STAGE_LOAD',rows.length,`insert into zsl2_location_stage(location_type,canonical_key,display_name,authority_status,identity_document,identity_sha256,revision_document,revision_sha256,latitude,longitude,source_key,release_id,ingest_run_id,raw_record_id,record_sha256)
 select
 x.location_type,x.canonical_key,x.display_name,x.authority_status,
 x.identity_document::jsonb,x.identity_sha256,
 x.revision_document::jsonb,x.revision_sha256,
 x.latitude::numeric(9,6),x.longitude::numeric(9,6),
 x.source_key,x.release_id::uuid,x.ingest_run_id::uuid,
 x.raw_record_id::uuid,x.record_sha256
 from unnest($1::text[],$2::text[],$3::text[],$4::text[],$5::text[],$6::text[],$7::text[],$8::text[],$9::text[],$10::text[],$11::text[],$12::text[],$13::text[],$14::text[],$15::text[])
 as x(location_type,canonical_key,display_name,authority_status,identity_document,identity_sha256,revision_document,revision_sha256,latitude,longitude,source_key,release_id,ingest_run_id,raw_record_id,record_sha256)`,[
  cols.location_type,cols.canonical_key,cols.display_name,cols.authority_status,cols.identity_document,cols.identity_sha256,cols.revision_document,cols.revision_sha256,cols.latitude,cols.longitude,cols.source_key,cols.release_id,cols.ingest_run_id,cols.raw_record_id,cols.record_sha256]);
 const drift=await timed(c,record,'LOCATION_IDENTITY_DRIFT_CHECK',rows.length,`select count(*)::text n from zsl2_location_stage s join zsl.locations l using(canonical_key) where l.identity_sha256<>s.identity_sha256`);
 if(BigInt(String(drift.rows[0].n))>0n)throw new Error(`LOCATION_IDENTITY_DRIFT_BATCH:${drift.rows[0].n}`);
 await timed(c,record,'LOCATION_BULK_UPSERT',rows.length,`insert into zsl.locations(location_type,canonical_key,display_name,authority_status,identity_document,identity_sha256)
 select distinct on(canonical_key) location_type,canonical_key,display_name,authority_status,identity_document,identity_sha256 from zsl2_location_stage order by canonical_key,raw_record_id
 on conflict(canonical_key) do nothing`);
 const resolved=await timed(c,record,'LOCATION_BULK_RESOLVE',rows.length,`select distinct s.canonical_key,l.location_id::text from zsl2_location_stage s join zsl.locations l on l.canonical_key=s.canonical_key and l.identity_sha256=s.identity_sha256`);
 for(const r of resolved.rows)map.set(String(r.canonical_key),String(r.location_id));
 const distinctKeys=new Set(inputs.map(x=>x.canonicalKey)); if(map.size!==distinctKeys.size)throw new Error(`LOCATION_RESOLUTION_CARDINALITY:${map.size}/${distinctKeys.size}`);
 await timed(c,record,'LOCATION_REVISION_BULK_INSERT',rows.length,`insert into zsl.zsl2_location_revisions(normalization_run_id,location_id,display_name,authority_status,latitude,longitude,point,source_key,source_release_id,source_ingest_run_id,source_record_sha256,revision_document,revision_sha256)
 select $1,l.location_id,s.display_name,s.authority_status,s.latitude,s.longitude,case when s.latitude is null or s.longitude is null then null else ST_SetSRID(ST_MakePoint(s.longitude,s.latitude),4326)::geography end,s.source_key,s.release_id,s.ingest_run_id,s.record_sha256,s.revision_document,s.revision_sha256
 from zsl2_location_stage s join zsl.locations l on l.canonical_key=s.canonical_key and l.identity_sha256=s.identity_sha256 on conflict(normalization_run_id,location_id,source_key,source_record_sha256) do nothing`,[runId]);
 await timed(c,record,'LOCATION_MEMBERSHIP_BULK_INSERT',rows.length,`insert into zsl.zsl2_location_run_memberships(normalization_run_id,location_id,source_key,release_id,ingest_run_id,source_record_sha256)
 select $1,l.location_id,s.source_key,s.release_id,s.ingest_run_id,s.record_sha256 from zsl2_location_stage s join zsl.locations l on l.canonical_key=s.canonical_key and l.identity_sha256=s.identity_sha256 on conflict do nothing`,[runId]);
 const types=new Set(inputs.map(x=>x.locationType));
 if(types.has('state'))await timed(c,record,'SUBTYPE_STATE_BULK_UPSERT',rows.length,`with x as(select distinct on(s.canonical_key) s.*,l.location_id from zsl2_location_stage s join zsl.locations l on l.canonical_key=s.canonical_key and l.identity_sha256=s.identity_sha256 where s.location_type='state' order by s.canonical_key,s.raw_record_id)
 insert into zsl.states(location_id,state_fips,usps_code,official_name) select location_id,identity_document->>'geoid',revision_document#>>'{attributes,usps}',revision_document#>>'{attributes,name}' from x
 on conflict(location_id) do update set usps_code=excluded.usps_code,official_name=excluded.official_name where zsl.states.state_fips=excluded.state_fips`);
 if(types.has('county'))await timed(c,record,'SUBTYPE_COUNTY_BULK_UPSERT',rows.length,`with x as(select distinct on(s.canonical_key) s.*,l.location_id from zsl2_location_stage s join zsl.locations l on l.canonical_key=s.canonical_key and l.identity_sha256=s.identity_sha256 where s.location_type='county' order by s.canonical_key,s.raw_record_id)
 insert into zsl.counties(location_id,county_fips,state_fips,official_name) select location_id,identity_document->>'geoid',left(identity_document->>'geoid',2),revision_document#>>'{attributes,name}' from x
 on conflict(location_id) do update set official_name=excluded.official_name where zsl.counties.county_fips=excluded.county_fips and zsl.counties.state_fips=excluded.state_fips`);
 if(types.has('place'))await timed(c,record,'SUBTYPE_PLACE_BULK_UPSERT',rows.length,`with x as(select distinct on(s.canonical_key) s.*,l.location_id from zsl2_location_stage s join zsl.locations l on l.canonical_key=s.canonical_key and l.identity_sha256=s.identity_sha256 where s.location_type='place' order by s.canonical_key,s.raw_record_id)
 insert into zsl.places(location_id,place_geoid,state_fips,official_name) select location_id,identity_document->>'geoid',left(identity_document->>'geoid',2),revision_document#>>'{attributes,name}' from x
 on conflict(location_id) do update set official_name=excluded.official_name where zsl.places.place_geoid=excluded.place_geoid and zsl.places.state_fips=excluded.state_fips`);
 if(types.has('zcta'))await timed(c,record,'SUBTYPE_ZCTA_BULK_UPSERT',rows.length,`with x as(select distinct on(s.canonical_key) s.*,l.location_id from zsl2_location_stage s join zsl.locations l on l.canonical_key=s.canonical_key and l.identity_sha256=s.identity_sha256 where s.location_type='zcta' order by s.canonical_key,s.raw_record_id)
 insert into zsl.zctas(location_id,zcta5,geoidfq) select location_id,identity_document->>'geoid',revision_document#>>'{attributes,geoidfq}' from x
 on conflict(location_id) do update set geoidfq=excluded.geoidfq where zsl.zctas.zcta5=excluded.zcta5`);
 if(types.has('postal_code'))await timed(c,record,'SUBTYPE_POSTAL_BULK_UPSERT',rows.length,`with x as(select distinct on(s.canonical_key) s.*,l.location_id from zsl2_location_stage s join zsl.locations l on l.canonical_key=s.canonical_key and l.identity_sha256=s.identity_sha256 where s.location_type='postal_code' order by s.canonical_key,s.raw_record_id)
 insert into zsl.postal_codes(location_id,postal_code,operational_authority_status) select location_id,identity_document->>'postal_code','HUD_OBSERVED_PENDING_USPS' from x
 on conflict(location_id) do update set postal_code=excluded.postal_code where zsl.postal_codes.operational_authority_status in('HUD_OBSERVED_PENDING_USPS','PENDING_USPS_ZSL3')`);
 if(types.has('cbsa'))await timed(c,record,'SUBTYPE_CBSA_BULK_UPSERT',rows.length,`with x as(select distinct on(s.canonical_key) s.*,l.location_id from zsl2_location_stage s join zsl.locations l on l.canonical_key=s.canonical_key and l.identity_sha256=s.identity_sha256 where s.location_type='cbsa' order by s.canonical_key,s.raw_record_id)
 insert into zsl.cbsa_metros(location_id,cbsa_code,official_name,name_authority_status) select location_id,identity_document->>'cbsa_code',null,'PENDING_CENSUS_OMB' from x
 on conflict(location_id) do update set cbsa_code=excluded.cbsa_code where zsl.cbsa_metros.official_name is null and zsl.cbsa_metros.name_authority_status='PENDING_CENSUS_OMB'`);
 return map;
}

async function ensureRelationshipStage(c:PoolClient){
 await c.query(`create temp table if not exists zsl2_relationship_stage(source_key text not null,release_id uuid not null,ingest_run_id uuid not null,raw_record_id uuid not null,record_sha256 text not null,parent_key text not null,child_key text not null,relationship_type text not null,authority text not null,res_ratio numeric(12,9),bus_ratio numeric(12,9),oth_ratio numeric(12,9),tot_ratio numeric(12,9),evidence_document jsonb not null,evidence_sha256 text not null) on commit delete rows`);
}

async function bulkRelationships(c:PoolClient,runId:string,rels:RelationshipStage[],record:OperationRecorder,writeRelationshipLineage:boolean):Promise<number>{
 if(rels.length===0)return 0; await ensureRelationshipStage(c); await c.query(`truncate zsl2_relationship_stage`);
 const a=(k:keyof RelationshipStage)=>rels.map(r=>r[k] as never);
 await timed(c,record,'RELATIONSHIP_STAGE_LOAD',rels.length,`insert into zsl2_relationship_stage(source_key,release_id,ingest_run_id,raw_record_id,record_sha256,parent_key,child_key,relationship_type,authority,res_ratio,bus_ratio,oth_ratio,tot_ratio,evidence_document,evidence_sha256)
 select source_key,release_id::uuid,ingest_run_id::uuid,raw_record_id::uuid,record_sha256,parent_key,child_key,relationship_type,authority,res_ratio::numeric,bus_ratio::numeric,oth_ratio::numeric,tot_ratio::numeric,evidence_document::jsonb,evidence_sha256
 from unnest($1::text[],$2::text[],$3::text[],$4::text[],$5::text[],$6::text[],$7::text[],$8::text[],$9::text[],$10::text[],$11::text[],$12::text[],$13::text[],$14::text[],$15::text[]) x(source_key,release_id,ingest_run_id,raw_record_id,record_sha256,parent_key,child_key,relationship_type,authority,res_ratio,bus_ratio,oth_ratio,tot_ratio,evidence_document,evidence_sha256)`,[
  a('source_key'),a('release_id'),a('ingest_run_id'),a('raw_record_id'),a('record_sha256'),a('parent_key'),a('child_key'),a('relationship_type'),a('authority'),rels.map(r=>r.ratios.res),rels.map(r=>r.ratios.bus),rels.map(r=>r.ratios.oth),rels.map(r=>r.ratios.tot),rels.map(r=>JSON.stringify(r.evidence_document)),a('evidence_sha256')]);
 const missing=await timed(c,record,'PARENT_CHILD_BULK_RESOLVE',rels.length,`select count(*)::text n from zsl2_relationship_stage s left join zsl.locations p on p.canonical_key=s.parent_key left join zsl.locations ch on ch.canonical_key=s.child_key where p.location_id is null or ch.location_id is null`);
 if(BigInt(String(missing.rows[0].n))>0n)throw new Error(`RELATIONSHIP_MISSING_ENDPOINT:${missing.rows[0].n}`);
 const drift=await timed(c,record,'RELATIONSHIP_DRIFT_CHECK',rels.length,`select count(*)::text n from zsl2_relationship_stage s join zsl.locations p on p.canonical_key=s.parent_key join zsl.locations ch on ch.canonical_key=s.child_key join zsl.location_relationships r on r.parent_location_id=p.location_id and r.child_location_id=ch.location_id and r.relationship_type=s.relationship_type and r.authority=s.authority and r.source_release_id=s.release_id where r.evidence_sha256<>s.evidence_sha256`);
 if(BigInt(String(drift.rows[0].n))>0n)throw new Error(`RELATIONSHIP_BATCH_DRIFT:${drift.rows[0].n}`);
 await timed(c,record,'RELATIONSHIP_BULK_UPSERT',rels.length,`insert into zsl.location_relationships(parent_location_id,child_location_id,relationship_type,authority,res_ratio,bus_ratio,oth_ratio,tot_ratio,source_release_id,source_ingest_run_id,source_record_sha256,evidence_document,evidence_sha256)
 select p.location_id,ch.location_id,s.relationship_type,s.authority,s.res_ratio,s.bus_ratio,s.oth_ratio,s.tot_ratio,s.release_id,s.ingest_run_id,s.record_sha256,s.evidence_document,s.evidence_sha256 from zsl2_relationship_stage s join zsl.locations p on p.canonical_key=s.parent_key join zsl.locations ch on ch.canonical_key=s.child_key
 on conflict(parent_location_id,child_location_id,relationship_type,authority,source_release_id) do nothing`);
 const bad=await timed(c,record,'RELATIONSHIP_ONE_TO_ONE_CHECK',rels.length,`select count(*)::text n from (select s.raw_record_id,count(r.relationship_id)c from zsl2_relationship_stage s join zsl.locations p on p.canonical_key=s.parent_key join zsl.locations ch on ch.canonical_key=s.child_key left join zsl.location_relationships r on r.parent_location_id=p.location_id and r.child_location_id=ch.location_id and r.relationship_type=s.relationship_type and r.authority=s.authority and r.source_release_id=s.release_id and r.evidence_sha256=s.evidence_sha256 group by s.raw_record_id having count(r.relationship_id)<>1)x`);
 if(BigInt(String(bad.rows[0].n))>0n)throw new Error(`RELATIONSHIP_ONE_TO_ONE_FAILURE:${bad.rows[0].n}`);
 await timed(c,record,'RELATIONSHIP_MEMBERSHIP_BULK_INSERT',rels.length,`insert into zsl.zsl2_relationship_run_memberships(normalization_run_id,relationship_id,source_key,release_id,ingest_run_id,source_record_sha256)
 select $1,r.relationship_id,s.source_key,s.release_id,s.ingest_run_id,s.record_sha256 from zsl2_relationship_stage s join zsl.locations p on p.canonical_key=s.parent_key join zsl.locations ch on ch.canonical_key=s.child_key join zsl.location_relationships r on r.parent_location_id=p.location_id and r.child_location_id=ch.location_id and r.relationship_type=s.relationship_type and r.authority=s.authority and r.source_release_id=s.release_id and r.evidence_sha256=s.evidence_sha256 on conflict do nothing`,[runId]);
 if(writeRelationshipLineage)await timed(c,record,'LINEAGE_BULK_INSERT',rels.length,`insert into zsl.zsl2_record_lineage(normalization_run_id,source_key,release_id,ingest_run_id,raw_record_id,raw_record_sha256,canonical_relationship_id,disposition)
 select $1,s.source_key,s.release_id,s.ingest_run_id,s.raw_record_id,s.record_sha256,r.relationship_id,'NORMALIZED_RELATIONSHIP' from zsl2_relationship_stage s join zsl.locations p on p.canonical_key=s.parent_key join zsl.locations ch on ch.canonical_key=s.child_key join zsl.location_relationships r on r.parent_location_id=p.location_id and r.child_location_id=ch.location_id and r.relationship_type=s.relationship_type and r.authority=s.authority and r.source_release_id=s.release_id and r.evidence_sha256=s.evidence_sha256 on conflict(normalization_run_id,source_key,raw_record_id) do nothing`,[runId]);
 return rels.length;
}

export async function processGazetteerPageSetBased(c:PoolClient,runId:string,page:CertifiedRawRecord[],record:OperationRecorder):Promise<BulkPageResult>{
 const inputs=page.map(normalizeGazetteer); await bulkLocations(c,runId,inputs,record);
 const rels:RelationshipStage[]=[];
 for(let i=0;i<page.length;i++){
  const r=page[i]!,x=inputs[i]!,d=x.identityDocument as Record<string,unknown>; let parentKey:string|null=null,type:string|null=null;
  if(x.locationType==='state'){parentKey='US:NATIONAL';type='CONTAINS';}
  else if(x.locationType==='county'||x.locationType==='place'){parentKey=`US:STATE:${String(d.geoid).slice(0,2)}`;type='STATE_OF';}
  if(parentKey&&type){const ev={parent:parentKey,child:x.canonicalKey,authority:'CENSUS',relationship_type:type,source_release_id:r.release_id};rels.push({source_key:r.source_key,release_id:r.release_id,ingest_run_id:r.ingest_run_id,raw_record_id:r.record_id,record_sha256:r.record_sha256,parent_key:parentKey,child_key:x.canonicalKey,relationship_type:type,authority:'CENSUS',ratios:{res:null,bus:null,oth:null,tot:null},evidence_document:ev,evidence_sha256:sha256Json(ev)});}
 }
 const relationships=await bulkRelationships(c,runId,rels,record,false);
 await timed(c,record,'LINEAGE_BULK_INSERT',page.length,`insert into zsl.zsl2_record_lineage(normalization_run_id,source_key,release_id,ingest_run_id,raw_record_id,raw_record_sha256,canonical_location_id,disposition)
 select $1,s.source_key,s.release_id,s.ingest_run_id,s.raw_record_id,s.record_sha256,l.location_id,'NORMALIZED_LOCATION' from zsl2_location_stage s join zsl.locations l on l.canonical_key=s.canonical_key and l.identity_sha256=s.identity_sha256 on conflict(normalization_run_id,source_key,raw_record_id) do nothing`,[runId]);
 return {records:page.length,locations:page.length,relationships,lineage:page.length};
}

export async function processHudPageSetBased(c:PoolClient,runId:string,source:string,page:CertifiedRawRecord[],record:OperationRecorder):Promise<BulkPageResult>{
 const postalInputs=page.map(normalizeHudPostalLocation);
 const postalLocationIds=await bulkLocations(c,runId,postalInputs,record);
 const outside:CertifiedRawRecord[]=[]; const areaRows:CertifiedRawRecord[]=[]; const normal:CertifiedRawRecord[]=[];
 const areaCodes:Record<string,string>={AS:'60',FM:'64',MH:'68',PW:'70'};
 for(const r of page){
  const state=String(r.record.state??'').trim().toUpperCase();
  const geoid=String(r.record.geoid??'').trim();
  if(source==='HUD_USPS_ZIP_CBSA'&&geoid==='99999')outside.push(r);
  else if(source==='HUD_USPS_ZIP_COUNTY'&&areaCodes[state]===geoid)areaRows.push(r);
  else normal.push(r);
 }
 if(outside.length){
  const zipKeys=outside.map(r=>`US:ZIP:${String(r.record.zip)}`);const ratios=outside.map(hudRatios);const docs=outside.map((r,i)=>({authority:'HUD_USPS',relationship_type:'POSTAL_OUTSIDE_CBSA',postal_key:zipKeys[i],ratios:ratios[i],source_record_sha256:r.record_sha256}));
  await timed(c,record,'HUD_OUTSIDE_CBSA_BULK_INSERT',outside.length,`insert into zsl.zsl2_postal_outside_cbsa_facts(normalization_run_id,postal_location_id,res_ratio,bus_ratio,oth_ratio,tot_ratio,source_release_id,source_ingest_run_id,source_record_sha256,evidence_document,evidence_sha256)
  select $1,l.location_id,x.res::numeric,x.bus::numeric,x.oth::numeric,x.tot::numeric,x.release_id::uuid,x.ingest_run_id::uuid,x.record_sha256,x.doc::jsonb,x.sha from unnest($2::text[],$3::text[],$4::text[],$5::text[],$6::text[],$7::text[],$8::text[],$9::text[],$10::text[],$11::text[])x(zip_key,res,bus,oth,tot,release_id,ingest_run_id,record_sha256,doc,sha) join zsl.locations l on l.canonical_key=x.zip_key on conflict(normalization_run_id,source_record_sha256) do nothing`,[runId,zipKeys,ratios.map(x=>x.res),ratios.map(x=>x.bus),ratios.map(x=>x.oth),ratios.map(x=>x.tot),outside.map(r=>r.release_id),outside.map(r=>r.ingest_run_id),outside.map(r=>r.record_sha256),docs.map(d=>JSON.stringify(d)),docs.map(sha256Json)]);
  await timed(c,record,'LINEAGE_BULK_INSERT',outside.length,`insert into zsl.zsl2_record_lineage(normalization_run_id,source_key,release_id,ingest_run_id,raw_record_id,raw_record_sha256,disposition,disposition_reason)
  select $1,x.source_key,x.release_id::uuid,x.ingest_run_id::uuid,x.raw_record_id::uuid,x.record_sha256,'IGNORED_BY_POLICY','HUD_CBSA_99999_OUTSIDE_CBSA' from unnest($2::text[],$3::text[],$4::text[],$5::text[],$6::text[])x(source_key,release_id,ingest_run_id,raw_record_id,record_sha256) on conflict(normalization_run_id,source_key,raw_record_id) do nothing`,[runId,outside.map(r=>r.source_key),outside.map(r=>r.release_id),outside.map(r=>r.ingest_run_id),outside.map(r=>r.record_id),outside.map(r=>r.record_sha256)]);
 }
 if(areaRows.length){
  const facts=areaRows.map(rr=>{
   const zip=String(rr.record.zip??'').trim();
   const state=String(rr.record.state??'').trim().toUpperCase();
   const area=String(rr.record.geoid??'').trim();
   const areaCodes:Record<string,string>={AS:'60',FM:'64',MH:'68',PW:'70'};
   if(!/^[0-9]{5}$/.test(zip)||areaCodes[state]!==area)throw new Error(`HUD_TERRITORIAL_AREA_IDENTITY_INVALID:${rr.record_id}`);
   const postalKey=`US:ZIP:${zip}`;
   const postalLocationId=postalLocationIds.get(postalKey);
   if(!postalLocationId)throw new Error(`HUD_TERRITORIAL_POSTAL_LOCATION_MISSING:${rr.record_id}`);
   const ratios=hudRatios(rr);
   const evidence={ratios,area_code:area,postal_key:postalKey,state_code:state,classification:'HUD_TERRITORIAL_AREA_NOT_COUNTY',source_record_sha256:rr.record_sha256};
   return {rr,zip,state,area,postalLocationId,ratios,evidence,evidenceSha:sha256Json(evidence)};
  });
  await timed(c,record,'HUD_TERRITORIAL_AREA_EVIDENCE_BULK_INSERT',facts.length,
   `insert into zsl.zsl2_postal_territorial_area_evidence_v214(normalization_run_id,source_key,release_id,ingest_run_id,raw_record_id,source_record_sha256,postal_location_id,postal_code,state_code,area_code,res_ratio,bus_ratio,oth_ratio,tot_ratio,evidence_document,evidence_sha256)
    select $1,x.source_key,x.release_id::uuid,x.ingest_run_id::uuid,x.raw_record_id::uuid,x.record_sha256,x.postal_location_id::uuid,x.postal_code,x.state_code,x.area_code,x.res::numeric,x.bus::numeric,x.oth::numeric,x.tot::numeric,x.evidence::jsonb,x.evidence_sha256
    from unnest($2::text[],$3::text[],$4::text[],$5::text[],$6::text[],$7::text[],$8::text[],$9::text[],$10::text[],$11::text[],$12::text[],$13::text[],$14::text[],$15::text[],$16::text[]) x(source_key,release_id,ingest_run_id,raw_record_id,record_sha256,postal_location_id,postal_code,state_code,area_code,res,bus,oth,tot,evidence,evidence_sha256)
    on conflict(normalization_run_id,source_key,raw_record_id) do nothing`,
   [runId,facts.map(x=>x.rr.source_key),facts.map(x=>x.rr.release_id),facts.map(x=>x.rr.ingest_run_id),facts.map(x=>x.rr.record_id),facts.map(x=>x.rr.record_sha256),facts.map(x=>x.postalLocationId),facts.map(x=>x.zip),facts.map(x=>x.state),facts.map(x=>x.area),facts.map(x=>x.ratios.res),facts.map(x=>x.ratios.bus),facts.map(x=>x.ratios.oth),facts.map(x=>x.ratios.tot),facts.map(x=>JSON.stringify(x.evidence)),facts.map(x=>x.evidenceSha)]);
  await timed(c,record,'LINEAGE_BULK_INSERT',facts.length,
   `insert into zsl.zsl2_record_lineage(normalization_run_id,source_key,release_id,ingest_run_id,raw_record_id,raw_record_sha256,canonical_location_id,disposition,disposition_reason)
    select $1,x.source_key,x.release_id::uuid,x.ingest_run_id::uuid,x.raw_record_id::uuid,x.record_sha256,x.location_id::uuid,'IGNORED_BY_POLICY','HUD_TERRITORIAL_AREA_NOT_COUNTY'
    from unnest($2::text[],$3::text[],$4::text[],$5::text[],$6::text[],$7::text[]) x(source_key,release_id,ingest_run_id,raw_record_id,record_sha256,location_id)
    on conflict(normalization_run_id,source_key,raw_record_id) do nothing`,
   [runId,facts.map(x=>x.rr.source_key),facts.map(x=>x.rr.release_id),facts.map(x=>x.rr.ingest_run_id),facts.map(x=>x.rr.record_id),facts.map(x=>x.rr.record_sha256),facts.map(x=>x.postalLocationId)]);
 }
 const relInputs=normal.map(r=>normalizeHudRelationship(r));
 const parentKeys=[...new Set(relInputs.map(r=>r.parentKey))];
 const pq=await timed(c,record,'HUD_PARENT_BULK_LOOKUP',parentKeys.length,`select canonical_key,location_id::text from zsl.locations where canonical_key=any($1::text[])`,[parentKeys]);
 const existing=new Set(pq.rows.map((r:any)=>String(r.canonical_key))); const missingCbsa=relInputs.filter(r=>r.relationshipType==='POSTAL_TO_CBSA'&&!existing.has(r.parentKey));
 if(missingCbsa.length){const byKey=new Map<string,CertifiedRawRecord>();for(const ri of missingCbsa){if(!byKey.has(ri.parentKey)){const rr=normal.find(r=>r.record_id===ri.recordId);if(rr)byKey.set(ri.parentKey,rr);}}
  const cbInputs=[...byKey.entries()].map(([key,r])=>({locationType:'cbsa',canonicalKey:key,displayName:null,authorityStatus:'PROVISIONAL',identityDocument:{authority:'HUD_USPS',type:'CBSA_CODE_ONLY',cbsa_code:key.slice(-5)},revisionDocument:{official_name_status:'PENDING_CENSUS_OMB'},sourceKey:r.source_key,releaseId:r.release_id,ingestRunId:r.ingest_run_id,recordId:r.record_id,recordSha256:r.record_sha256} as CanonicalLocationInput));
  await bulkLocations(c,runId,cbInputs,record); for(const x of cbInputs)existing.add(x.canonicalKey);
 }
 const missingCounty=relInputs.filter(r=>r.relationshipType==='POSTAL_TO_COUNTY'&&!existing.has(r.parentKey));
 const territorialMissing=missingCounty.filter(r=>/^US:COUNTY:(60|66|69|72|78)[0-9]{3}$/.test(r.parentKey));
 const fatalMissing=missingCounty.filter(r=>!/^US:COUNTY:(60|66|69|72|78)[0-9]{3}$/.test(r.parentKey));
 if(territorialMissing.length){
  const rrMap=new Map(normal.map(r=>[r.record_id,r]));
  const trs=territorialMissing.map(x=>{const rr=rrMap.get(x.recordId);if(!rr)throw new Error(`TERRITORIAL_RAW_RECORD_MISSING:${x.recordId}`);const zip=String(rr.record.zip??'');const geoid=String(rr.record.geoid??'');if(!/^[0-9]{5}$/.test(zip)||!/^(?:60|66|69|72|78)[0-9]{3}$/.test(geoid))throw new Error(`TERRITORIAL_IDENTITY_INVALID:${x.recordId}`);const ev={policy:'TCDS_ZSL2_TERRITORIAL_PENDING_V2_1_4',source_key:rr.source_key,release_id:rr.release_id,ingest_run_id:rr.ingest_run_id,raw_record_id:rr.record_id,raw_record_sha256:rr.record_sha256,postal_code:zip,territorial_county_geoid:geoid,expected_parent_canonical_key:x.parentKey,decision:'PENDING_EXTERNAL_AUTHORITY',no_county_created:true,no_relationship_created:true};return{rr,zip,geoid,parent:x.parentKey,evidence:ev,evidenceSha:sha256Json(ev)};});
  await timed(c,record,'HUD_TERRITORIAL_PENDING_BULK_INSERT',trs.length,`insert into zsl.zsl2_territorial_pending_evidence_v214(normalization_run_id,source_key,release_id,ingest_run_id,raw_record_id,raw_record_sha256,postal_code,territorial_county_geoid,expected_parent_canonical_key,evidence,evidence_sha256)
  select $1,x.source_key,x.release_id::uuid,x.ingest_run_id::uuid,x.raw_record_id::uuid,x.raw_record_sha256,x.postal_code,x.geoid,x.parent_key,x.evidence::jsonb,x.evidence_sha256 from unnest($2::text[],$3::text[],$4::text[],$5::text[],$6::text[],$7::text[],$8::text[],$9::text[],$10::text[],$11::text[]) x(source_key,release_id,ingest_run_id,raw_record_id,raw_record_sha256,postal_code,geoid,parent_key,evidence,evidence_sha256) on conflict(normalization_run_id,source_key,raw_record_id,expected_parent_canonical_key) do nothing`,[runId,trs.map(x=>x.rr.source_key),trs.map(x=>x.rr.release_id),trs.map(x=>x.rr.ingest_run_id),trs.map(x=>x.rr.record_id),trs.map(x=>x.rr.record_sha256),trs.map(x=>x.zip),trs.map(x=>x.geoid),trs.map(x=>x.parent),trs.map(x=>JSON.stringify(x.evidence)),trs.map(x=>x.evidenceSha)]);
  await timed(c,record,'LINEAGE_BULK_INSERT',trs.length,`insert into zsl.zsl2_record_lineage(normalization_run_id,source_key,release_id,ingest_run_id,raw_record_id,raw_record_sha256,disposition,disposition_reason)
  select $1,x.source_key,x.release_id::uuid,x.ingest_run_id::uuid,x.raw_record_id::uuid,x.record_sha256,'IGNORED_BY_POLICY','PENDING_TERRITORIAL_AUTHORITY' from unnest($2::text[],$3::text[],$4::text[],$5::text[],$6::text[])x(source_key,release_id,ingest_run_id,raw_record_id,record_sha256) on conflict(normalization_run_id,source_key,raw_record_id) do nothing`,[runId,trs.map(x=>x.rr.source_key),trs.map(x=>x.rr.release_id),trs.map(x=>x.rr.ingest_run_id),trs.map(x=>x.rr.record_id),trs.map(x=>x.rr.record_sha256)]);
 }
 if(fatalMissing.length){
  const rrMap=new Map(normal.map(r=>[r.record_id,r]));
  await timed(c,record,'HUD_ORPHAN_CONFLICT_BULK_INSERT',fatalMissing.length,`insert into zsl.zsl2_conflicts(normalization_run_id,conflict_code,severity,entity_key,source_key,details,details_sha256)
  select $1,'ORPHAN_PARENT','FATAL',x.parent_key,$2,jsonb_build_object('record_sha256',x.record_sha256),encode(digest(convert_to(jsonb_build_object('record_sha256',x.record_sha256)::text,'UTF8'),'sha256'),'hex') from unnest($3::text[],$4::text[])x(parent_key,record_sha256)`,[runId,source,fatalMissing.map(x=>x.parentKey),fatalMissing.map(x=>x.recordSha256)]);
  const missIds=new Set(fatalMissing.map(x=>x.recordId));const missRows=normal.filter(r=>missIds.has(r.record_id));
  await timed(c,record,'LINEAGE_BULK_INSERT',missRows.length,`insert into zsl.zsl2_record_lineage(normalization_run_id,source_key,release_id,ingest_run_id,raw_record_id,raw_record_sha256,disposition,disposition_reason)
  select $1,x.source_key,x.release_id::uuid,x.ingest_run_id::uuid,x.raw_record_id::uuid,x.record_sha256,'CONFLICT','ORPHAN_PARENT' from unnest($2::text[],$3::text[],$4::text[],$5::text[],$6::text[])x(source_key,release_id,ingest_run_id,raw_record_id,record_sha256) on conflict(normalization_run_id,source_key,raw_record_id) do nothing`,[runId,missRows.map(r=>r.source_key),missRows.map(r=>r.release_id),missRows.map(r=>r.ingest_run_id),missRows.map(r=>r.record_id),missRows.map(r=>r.record_sha256)]);
 }
 const missingIds=new Set(missingCounty.map(x=>x.recordId)); const good=relInputs.filter(x=>!missingIds.has(x.recordId));
 const rels:RelationshipStage[]=good.map(x=>{const ev={parent:x.parentKey,child:x.childKey,ratios:x.ratios,authority:x.authority,relationship_type:x.relationshipType,source_release_id:x.releaseId};return{source_key:x.sourceKey,release_id:x.releaseId,ingest_run_id:x.ingestRunId,raw_record_id:x.recordId,record_sha256:x.recordSha256,parent_key:x.parentKey,child_key:x.childKey,relationship_type:x.relationshipType,authority:x.authority,ratios:x.ratios,evidence_document:ev,evidence_sha256:sha256Json(ev)}});
 const relationships=await bulkRelationships(c,runId,rels,record,true);
 return {records:page.length,locations:page.length+missingCbsa.length,relationships,lineage:outside.length+areaRows.length+missingCounty.length+relationships};
}
