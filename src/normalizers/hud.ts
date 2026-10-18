import type {CertifiedRawRecord,CanonicalLocationInput,RelationshipInput} from '../core/types.js';
const ratio=(v:unknown)=>{if(v===null||v===undefined||v==='')return null;const n=Number(v);if(!Number.isFinite(n)||n<0||n>1)throw new Error(`INVALID_HUD_RATIO:${String(v)}`);return n};
export const hudRatios=(r:CertifiedRawRecord)=>({res:ratio(r.record.res_ratio),bus:ratio(r.record.bus_ratio),oth:ratio(r.record.oth_ratio),tot:ratio(r.record.tot_ratio)});
export function normalizeHudPostalLocation(r:CertifiedRawRecord):CanonicalLocationInput{
 const z=String(r.record.zip??''); if(!/^\d{5}$/.test(z))throw new Error(`INVALID_HUD_ZIP:${z}`);
 return {locationType:'postal_code',canonicalKey:`US:ZIP:${z}`,displayName:`ZIP ${z}`,authorityStatus:'PENDING_EXTERNAL_AUTHORITY',
   identityDocument:{authority:'HUD_USPS',type:'POSTAL_CODE_OBSERVED',postal_code:z},
   revisionDocument:{operational_status:'PENDING_USPS_ZSL3'},
   sourceKey:r.source_key,releaseId:r.release_id,ingestRunId:r.ingest_run_id,recordId:r.record_id,recordSha256:r.record_sha256};
}
export function normalizeHudRelationship(r:CertifiedRawRecord):RelationshipInput{
 const z=String(r.record.zip??''),g=String(r.record.geoid??'');
 if(!/^\d{5}$/.test(z)||!/^\d{5}$/.test(g))throw new Error('INVALID_HUD_RELATIONSHIP_ID');
 const isCounty=r.source_key==='HUD_USPS_ZIP_COUNTY';
 if(!isCounty && r.source_key!=='HUD_USPS_ZIP_CBSA')throw new Error(`INVALID_HUD_SOURCE:${r.source_key}`);
 if(!isCounty && g==='99999')throw new Error('HUD_CBSA_99999_OUTSIDE_CBSA');
 return {parentKey:isCounty?`US:COUNTY:${g}`:`US:CBSA:${g}`,childKey:`US:ZIP:${z}`,relationshipType:isCounty?'POSTAL_TO_COUNTY':'POSTAL_TO_CBSA',authority:'HUD_USPS',
   ratios:hudRatios(r),sourceKey:r.source_key,releaseId:r.release_id,ingestRunId:r.ingest_run_id,recordId:r.record_id,recordSha256:r.record_sha256};
}
