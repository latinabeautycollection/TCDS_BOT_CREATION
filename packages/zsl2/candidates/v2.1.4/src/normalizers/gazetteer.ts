import type {CertifiedRawRecord,CanonicalLocationInput} from '../core/types.js';

const coord=(v:unknown,name:string,min:number,max:number)=>{const s=String(v??'').trim();if(!/^[+-]?(?:\d+)(?:\.\d+)?$/.test(s))throw new Error(`INVALID_${name}:${s}`);const n=Number(s);if(!Number.isFinite(n)||n<min||n>max)throw new Error(`INVALID_${name}:${s}`);return n};
const text=(v:unknown,name:string)=>{const s=String(v??'').normalize('NFC').trim();if(!s)throw new Error(`MISSING_${name}`);return s};

export function normalizeGazetteer(r:CertifiedRawRecord):CanonicalLocationInput{
 const x=r.record,k=r.source_key;const common={sourceKey:k,releaseId:r.release_id,ingestRunId:r.ingest_run_id,recordId:r.record_id,recordSha256:r.record_sha256};
 const geoid=text(x.GEOID,'GEOID'),lat=coord(x.INTPTLAT,'LATITUDE',-90,90),lon=coord(x.INTPTLONG,'LONGITUDE',-180,180);
 if(k==='CENSUS_GAZETTEER_STATE'){if(!/^\d{2}$/.test(geoid))throw new Error(`INVALID_STATE_GEOID:${geoid}`);const usps=text(x.USPS,'USPS').toUpperCase(),name=text(x.NAME,'NAME');return {...common,locationType:'state',canonicalKey:`US:STATE:${geoid}`,displayName:name,authorityStatus:'AUTHORITATIVE',identityDocument:{authority:'CENSUS',type:'STATE',geoid},revisionDocument:{name,usps},latitude:lat,longitude:lon};}
 if(k==='CENSUS_GAZETTEER_COUNTY'){if(!/^\d{5}$/.test(geoid))throw new Error(`INVALID_COUNTY_GEOID:${geoid}`);const usps=text(x.USPS,'USPS').toUpperCase(),name=text(x.NAME,'NAME');return {...common,locationType:'county',canonicalKey:`US:COUNTY:${geoid}`,displayName:name,authorityStatus:'AUTHORITATIVE',identityDocument:{authority:'CENSUS',type:'COUNTY',geoid},revisionDocument:{name,usps},latitude:lat,longitude:lon};}
 if(k==='CENSUS_GAZETTEER_PLACE'){if(!/^\d{7}$/.test(geoid))throw new Error(`INVALID_PLACE_GEOID:${geoid}`);const usps=text(x.USPS,'USPS').toUpperCase(),name=text(x.NAME,'NAME');return {...common,locationType:'place',canonicalKey:`US:PLACE:${geoid}`,displayName:name,authorityStatus:'AUTHORITATIVE',identityDocument:{authority:'CENSUS',type:'PLACE',geoid},revisionDocument:{name,usps},latitude:lat,longitude:lon};}
 if(k==='CENSUS_GAZETTEER_ZCTA'){if(!/^\d{5}$/.test(geoid))throw new Error(`INVALID_ZCTA_GEOID:${geoid}`);const geoidfq=text(x.GEOIDFQ,'GEOIDFQ');return {...common,locationType:'zcta',canonicalKey:`US:ZCTA:${geoid}`,displayName:`ZCTA ${geoid}`,authorityStatus:'AUTHORITATIVE',identityDocument:{authority:'CENSUS',type:'ZCTA',geoid},revisionDocument:{geoidfq},latitude:lat,longitude:lon};}
 throw new Error(`UNSUPPORTED_GAZETTEER_SOURCE:${k}`);
}
