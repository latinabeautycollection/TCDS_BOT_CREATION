import type pg from 'pg';
import {sha256Json} from '../core/hash.js';
import type {CertifiedRawRecord,CanonicalLocationInput} from '../core/types.js';
import {normalizeGazetteer} from '../normalizers/gazetteer.js';
import {normalizeHudPostalLocation,normalizeHudRelationship,hudRatios} from '../normalizers/hud.js';

const PAGE_SIZE=Number(process.env.ZSL2_PAGE_SIZE??5000);

async function* boundCertifiedRecords(c:pg.PoolClient,runId:string,sourceKey:string):AsyncGenerator<CertifiedRawRecord>{
 let offset=0;
 for(;;){
  const q=await c.query(`
    select cr.source_key,cr.release_id::text,cr.release_key,cr.ingest_run_id::text,cr.artifact_id::text,
           cr.ordinal,cr.natural_key,cr.record_id::text,cr.record,cr.record_sha256
    from zsl.zsl2_source_bindings b
    join zsl.certified_release_records cr
      on cr.source_key=b.source_key and cr.release_id=b.release_id and cr.ingest_run_id=b.ingest_run_id
    where b.normalization_run_id=$1 and b.source_key=$2
    order by cr.ordinal,cr.record_id
    limit $3 offset $4`,[runId,sourceKey,PAGE_SIZE,offset]);
  if(q.rowCount===0)break;
  for(const row of q.rows)yield row as CertifiedRawRecord;
  offset+=q.rowCount??0;
 }
}

async function upsertLocation(c:pg.PoolClient,runId:string,x:CanonicalLocationInput):Promise<string>{
 const identityHash=sha256Json(x.identityDocument);
 const q=await c.query(`
   insert into zsl.locations(location_type,canonical_key,display_name,authority_status,identity_document,identity_sha256)
   values($1,$2,$3,$4,$5::jsonb,$6)
   on conflict(canonical_key) do update set canonical_key=excluded.canonical_key
   where zsl.locations.identity_sha256=excluded.identity_sha256
   returning location_id::text`,[x.locationType,x.canonicalKey,x.displayName,x.authorityStatus,JSON.stringify(x.identityDocument),identityHash]);
 if(q.rowCount!==1)throw new Error(`IDENTITY_DRIFT:${x.canonicalKey}`);
 const id=String(q.rows[0].location_id);
 const rev={identity:x.identityDocument,attributes:x.revisionDocument,display_name:x.displayName,authority_status:x.authorityStatus,latitude:x.latitude??null,longitude:x.longitude??null};
 const revSha=sha256Json(rev);
 await c.query(`
   insert into zsl.zsl2_location_revisions(
     normalization_run_id,location_id,display_name,authority_status,latitude,longitude,point,
     source_key,source_release_id,source_ingest_run_id,source_record_sha256,revision_document,revision_sha256)
   values($1,$2,$3,$4,$5,$6,
     case when $5::numeric is null or $6::numeric is null then null else ST_SetSRID(ST_MakePoint($6,$5),4326)::geography end,
     $7,$8,$9,$10,$11::jsonb,$12)
   on conflict(normalization_run_id,location_id,source_key,source_record_sha256) do nothing`,
   [runId,id,x.displayName,x.authorityStatus,x.latitude??null,x.longitude??null,x.sourceKey,x.releaseId,x.ingestRunId,x.recordSha256,JSON.stringify(rev),revSha]);
 await c.query(`insert into zsl.zsl2_location_run_memberships(normalization_run_id,location_id,source_key,release_id,ingest_run_id,source_record_sha256)
   values($1,$2,$3,$4,$5,$6) on conflict do nothing`,[runId,id,x.sourceKey,x.releaseId,x.ingestRunId,x.recordSha256]);
 return id;
}

async function projectSubtype(c:pg.PoolClient,x:CanonicalLocationInput,id:string){
 const d:any={...x.identityDocument,...x.revisionDocument};
 if(x.locationType==='state')await c.query(`insert into zsl.states(location_id,state_fips,usps_code,official_name) values($1,$2,$3,$4) on conflict(location_id) do nothing`,[id,d.geoid,d.usps,d.name]);
 if(x.locationType==='county')await c.query(`insert into zsl.counties(location_id,county_fips,state_fips,official_name) values($1,$2,$3,$4) on conflict(location_id) do nothing`,[id,d.geoid,String(d.geoid).slice(0,2),d.name]);
 if(x.locationType==='place')await c.query(`insert into zsl.places(location_id,place_geoid,state_fips,official_name) values($1,$2,$3,$4) on conflict(location_id) do nothing`,[id,d.geoid,String(d.geoid).slice(0,2),d.name]);
 if(x.locationType==='zcta')await c.query(`insert into zsl.zctas(location_id,zcta5,geoidfq) values($1,$2,$3) on conflict(location_id) do nothing`,[id,d.geoid,d.geoidfq]);
 if(x.locationType==='postal_code')await c.query(`insert into zsl.postal_codes(location_id,postal_code,operational_authority_status) values($1,$2,'HUD_OBSERVED_PENDING_USPS') on conflict(location_id) do nothing`,[id,d.postal_code]);
 if(x.locationType==='cbsa')await c.query(`insert into zsl.cbsa_metros(location_id,cbsa_code,official_name,name_authority_status) values($1,$2,null,'PENDING_CENSUS_OMB') on conflict(location_id) do nothing`,[id,d.cbsa_code]);
}

async function relationship(c:pg.PoolClient,runId:string,parentId:string,childId:string,type:string,authority:string,r:CertifiedRawRecord,doc:Record<string,unknown>,ratios?:{res:number|null;bus:number|null;oth:number|null;tot:number|null}){
 const ev={...doc,authority,relationship_type:type,source_record_sha256:r.record_sha256};
 const h=sha256Json(ev);
 const q=await c.query(`insert into zsl.location_relationships(parent_location_id,child_location_id,relationship_type,authority,res_ratio,bus_ratio,oth_ratio,tot_ratio,source_release_id,source_ingest_run_id,source_record_sha256,evidence_document,evidence_sha256)
 values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12::jsonb,$13)
 on conflict(parent_location_id,child_location_id,relationship_type,authority,source_release_id)
 do update set evidence_sha256=excluded.evidence_sha256 where zsl.location_relationships.evidence_sha256=excluded.evidence_sha256
 returning relationship_id::text`,[parentId,childId,type,authority,ratios?.res??null,ratios?.bus??null,ratios?.oth??null,ratios?.tot??null,r.release_id,r.ingest_run_id,r.record_sha256,JSON.stringify(ev),h]);
 if(q.rowCount!==1)throw new Error(`RELATIONSHIP_DRIFT:${type}:${parentId}:${childId}`);
 const relId=String(q.rows[0].relationship_id);
 await c.query(`insert into zsl.zsl2_relationship_run_memberships(normalization_run_id,relationship_id,source_key,release_id,ingest_run_id,source_record_sha256)
   values($1,$2,$3,$4,$5,$6) on conflict do nothing`,[runId,relId,r.source_key,r.release_id,r.ingest_run_id,r.record_sha256]);
 return relId;
}

async function deriveGazetteerHierarchy(c:pg.PoolClient,runId:string,x:CanonicalLocationInput,id:string,r:CertifiedRawRecord){
 const d:any=x.identityDocument;
 if(x.locationType==='state'){
   const q=await c.query(`select location_id::text from zsl.locations where canonical_key='US:NATIONAL'`);
   if(q.rowCount!==1)throw new Error('MISSING_NATIONAL_PARENT');
   await relationship(c,runId,String(q.rows[0].location_id),id,'CONTAINS','CENSUS',r,{parent:'US:NATIONAL',child:x.canonicalKey});
 }
 if(x.locationType==='county'||x.locationType==='place'){
   const stateFips=String(d.geoid).slice(0,2),parentKey=`US:STATE:${stateFips}`;
   const q=await c.query(`select location_id::text from zsl.locations where canonical_key=$1`,[parentKey]);
   if(q.rowCount!==1)throw new Error(`MISSING_STATE_PARENT:${parentKey}`);
   await relationship(c,runId,String(q.rows[0].location_id),id,'STATE_OF','CENSUS',r,{parent:parentKey,child:x.canonicalKey});
 }
}

async function lineageRow(c:pg.PoolClient,run:string,r:CertifiedRawRecord,loc:string|null,rel:string|null,disp:string,reason:string|null=null){
 await c.query(`insert into zsl.zsl2_record_lineage(normalization_run_id,source_key,release_id,ingest_run_id,raw_record_id,raw_record_sha256,canonical_location_id,canonical_relationship_id,disposition,disposition_reason)
 values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) on conflict do nothing`,[run,r.source_key,r.release_id,r.ingest_run_id,r.record_id,r.record_sha256,loc,rel,disp,reason]);
}
async function conflict(c:pg.PoolClient,run:string,code:string,severity:string,key:string,source:string,details:unknown){
 await c.query(`insert into zsl.zsl2_conflicts(normalization_run_id,conflict_code,severity,entity_key,source_key,details,details_sha256) values($1,$2,$3,$4,$5,$6::jsonb,$7)`,[run,code,severity,key,source,JSON.stringify(details),sha256Json(details)]);
}

export async function normalizeAll(c:pg.PoolClient,runId:string,sources:string[]):Promise<{locations:number,relationships:number,lineage:number}>{
 let locations=0,relationships=0,lineage=0;
 for(const source of sources){
   for await(const r of boundCertifiedRecords(c,runId,source)){
    if(source.startsWith('CENSUS_GAZETTEER_')){
      const x=normalizeGazetteer(r),id=await upsertLocation(c,runId,x);locations++;
      await projectSubtype(c,x,id);await deriveGazetteerHierarchy(c,runId,x,id,r);
      await lineageRow(c,runId,r,id,null,'NORMALIZED_LOCATION');lineage++;
    }else if(source.startsWith('HUD_USPS_')){
      const p=normalizeHudPostalLocation(r),zipId=await upsertLocation(c,runId,p);await projectSubtype(c,p,zipId);locations++;
      if(source==='HUD_USPS_ZIP_CBSA'&&String(r.record.geoid??'')==='99999'){
        const ratios=hudRatios(r);const ev={authority:'HUD_USPS',relationship_type:'POSTAL_OUTSIDE_CBSA',postal_key:p.canonicalKey,ratios,source_record_sha256:r.record_sha256};
        await c.query(`insert into zsl.zsl2_postal_outside_cbsa_facts(normalization_run_id,postal_location_id,res_ratio,bus_ratio,oth_ratio,tot_ratio,source_release_id,source_ingest_run_id,source_record_sha256,evidence_document,evidence_sha256)
          values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11) on conflict(normalization_run_id,source_record_sha256) do nothing`,[runId,zipId,ratios.res,ratios.bus,ratios.oth,ratios.tot,r.release_id,r.ingest_run_id,r.record_sha256,JSON.stringify(ev),sha256Json(ev)]);
        await lineageRow(c,runId,r,null,null,'IGNORED_BY_POLICY','HUD_CBSA_99999_OUTSIDE_CBSA');lineage++;continue;
      }
      const rel=normalizeHudRelationship(r);
      let pq=await c.query(`select location_id::text from zsl.locations where canonical_key=$1`,[rel.parentKey]);
      if(pq.rowCount===0&&rel.relationshipType==='POSTAL_TO_CBSA'){
        const code=rel.parentKey.slice(-5);
        const cb:CanonicalLocationInput={locationType:'cbsa',canonicalKey:rel.parentKey,displayName:null,authorityStatus:'PROVISIONAL',identityDocument:{authority:'HUD_USPS',type:'CBSA_CODE_ONLY',cbsa_code:code},revisionDocument:{official_name_status:'PENDING_CENSUS_OMB'},sourceKey:r.source_key,releaseId:r.release_id,ingestRunId:r.ingest_run_id,recordId:r.record_id,recordSha256:r.record_sha256};
        const cbid=await upsertLocation(c,runId,cb);await projectSubtype(c,cb,cbid);locations++;pq={...pq,rowCount:1,rows:[{location_id:cbid}]} as any;
      }
      if(pq.rowCount===0){await conflict(c,runId,'ORPHAN_PARENT','FATAL',rel.parentKey,source,{record_sha256:r.record_sha256});continue;}
      const relId=await relationship(c,runId,String(pq.rows[0].location_id),zipId,rel.relationshipType,rel.authority,r,{parent:rel.parentKey,child:rel.childKey,ratios:rel.ratios},rel.ratios);
      relationships++;await lineageRow(c,runId,r,null,relId,'NORMALIZED_RELATIONSHIP');lineage++;
    }
   }
 }
 return {locations,relationships,lineage};
}
