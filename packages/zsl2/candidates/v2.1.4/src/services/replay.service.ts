import type {PoolClient} from 'pg';
import {sha256Json} from '../core/hash.js';
import {normalizeDecimal} from '../core/exact.js';
import {normalizeGazetteer} from '../normalizers/gazetteer.js';
import {normalizeHudPostalLocation,normalizeHudRelationship,hudRatios} from '../normalizers/hud.js';
import type {CertifiedRawRecord} from '../core/types.js';

const eqDec=(a:unknown,b:string|null)=>b===null?a===null:normalizeDecimal(a,'db_ratio',9)===b;

export async function deterministicReplay(c:PoolClient,runId:string){
 const q=await c.query(`select l.source_key,l.release_id::text,b.release_key,l.ingest_run_id::text,cr.artifact_id::text,cr.ordinal::text,cr.natural_key,l.raw_record_id::text record_id,cr.record,l.raw_record_sha256 record_sha256,l.canonical_location_id::text,l.canonical_relationship_id::text,l.disposition,l.disposition_reason
 from zsl.zsl2_record_lineage l join zsl.zsl2_source_bindings b on b.normalization_run_id=l.normalization_run_id and b.source_key=l.source_key join zsl.certified_release_records cr on cr.source_key=l.source_key and cr.release_id=l.release_id and cr.ingest_run_id=l.ingest_run_id and cr.record_id=l.raw_record_id
 where l.normalization_run_id=$1 order by l.source_key,cr.ordinal,cr.record_id`,[runId]);
 let checked=0,failed=0;const failures:string[]=[];
 for(const row of q.rows){
  const r=row as CertifiedRawRecord & {canonical_location_id:string|null;canonical_relationship_id:string|null;disposition:string;disposition_reason:string|null};
  if(r.disposition==='NORMALIZED_LOCATION'){
   const n=r.source_key.startsWith('CENSUS_GAZETTEER_')?normalizeGazetteer(r):normalizeHudPostalLocation(r);const h=sha256Json(n.identityDocument);
   const x=await c.query(`select canonical_key,identity_sha256 from zsl.locations where location_id=$1`,[r.canonical_location_id]);const revDoc={identity:n.identityDocument,attributes:n.revisionDocument,display_name:n.displayName,authority_status:n.authorityStatus,latitude:n.latitude??null,longitude:n.longitude??null};const rev=await c.query(`select revision_sha256 from zsl.zsl2_location_revisions where normalization_run_id=$1 and location_id=$2 and source_key=$3 and source_record_sha256=$4`,[runId,r.canonical_location_id,r.source_key,r.record_sha256]);checked++;if(x.rowCount!==1||x.rows[0].canonical_key!==n.canonicalKey||x.rows[0].identity_sha256!==h||rev.rowCount!==1||rev.rows[0].revision_sha256!==sha256Json(revDoc)){failed++;failures.push(`LOCATION:${r.source_key}:${r.record_id}`);}
  }else if(r.disposition==='NORMALIZED_RELATIONSHIP'){
   const n=normalizeHudRelationship(r);const x=await c.query(`select p.canonical_key parent_key,ch.canonical_key child_key,lr.relationship_type,lr.res_ratio,lr.bus_ratio,lr.oth_ratio,lr.tot_ratio,lr.evidence_sha256 from zsl.location_relationships lr join zsl.locations p on p.location_id=lr.parent_location_id join zsl.locations ch on ch.location_id=lr.child_location_id where lr.relationship_id=$1`,[r.canonical_relationship_id]);checked++;if(x.rowCount!==1){failed++;failures.push(`REL_MISSING:${r.record_id}`);continue;}const z=x.rows[0];const ev={parent:n.parentKey,child:n.childKey,ratios:n.ratios,authority:n.authority,relationship_type:n.relationshipType,source_release_id:r.release_id};const ok=z.parent_key===n.parentKey&&z.child_key===n.childKey&&z.relationship_type===n.relationshipType&&eqDec(z.res_ratio,n.ratios.res)&&eqDec(z.bus_ratio,n.ratios.bus)&&eqDec(z.oth_ratio,n.ratios.oth)&&eqDec(z.tot_ratio,n.ratios.tot)&&z.evidence_sha256===sha256Json(ev);if(!ok){failed++;failures.push(`REL_MISMATCH:${r.record_id}`);}
  }else if(r.disposition==='IGNORED_BY_POLICY'&&r.source_key==='HUD_USPS_ZIP_CBSA'&&String(r.record.geoid??'')==='99999'){
   const ratios=hudRatios(r);const x=await c.query(`select res_ratio,bus_ratio,oth_ratio,tot_ratio from zsl.zsl2_postal_outside_cbsa_facts where normalization_run_id=$1 and source_record_sha256=$2`,[runId,r.record_sha256]);checked++;if(x.rowCount!==1||!eqDec(x.rows[0].res_ratio,ratios.res)||!eqDec(x.rows[0].bus_ratio,ratios.bus)||!eqDec(x.rows[0].oth_ratio,ratios.oth)||!eqDec(x.rows[0].tot_ratio,ratios.tot)){failed++;failures.push(`OUTSIDE_CBSA_FACT_MISMATCH:${r.record_id}`);}
  }else if(r.disposition==='CONFLICT'){checked++;const x=await c.query(`select count(*)::text n from zsl.zsl2_conflicts where normalization_run_id=$1 and source_key=$2 and details->>'record_sha256'=$3`,[runId,r.source_key,r.record_sha256]);if(BigInt(String(x.rows[0].n))===0n){failed++;failures.push(`CONFLICT_EVIDENCE_MISSING:${r.record_id}`);}}
  else {checked++;failed++;failures.push(`UNSUPPORTED_DISPOSITION:${r.disposition}:${r.record_id}`);}
 }
 const bound=await c.query(`select count(*)::text n from zsl.certified_release_records cr join zsl.zsl2_source_bindings b on b.normalization_run_id=$1 and cr.source_key=b.source_key and cr.release_id=b.release_id and cr.ingest_run_id=b.ingest_run_id`,[runId]);const expected=BigInt(String(bound.rows[0].n));
 return {checked,failed,expected:expected.toString(),coverage100:BigInt(checked)===expected,pass:checked>0&&failed===0&&BigInt(checked)===expected,failures:failures.slice(0,100)};
}
