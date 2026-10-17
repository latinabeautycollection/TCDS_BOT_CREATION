import type{PoolClient}from'pg';import type{GeographyCrosswalk}from'../core/types.js';
function stateFips(record:any):string|null{
 const raw=String(record.state??record.STATE??record.GeoFIPS??record.GeoFips??'').replace(/[^0-9]/g,'');
 // BEA state GeoFIPS is the five-digit state summary code (for example 01000).
 // Its state FIPS is the leading pair, not the trailing zeros.
 const state=raw.length>=5?raw.slice(0,2):raw.padStart(2,'0').slice(-2);
 return state&&state!=='00'?state:null;
}
export function canonicalLocationKey(scope:string,record:any,source?:{sourceKey:string;sourceVintage:string},crosswalks:GeographyCrosswalk[]=[]):string|null{
 let key:string|null=null;
 switch(scope){case'STATE':{const s=stateFips(record);if(s)key=`US:STATE:${s}`;break}case'COUNTY':{const st=String(record.state??record.STATE??'').padStart(2,'0');const co=String(record.county??record.COUNTY??'').padStart(3,'0');if(st.trim()&&co.trim())key=`US:COUNTY:${st}${co}`;break}case'PLACE':{const st=String(record.state??record.STATE??'').padStart(2,'0');const pl=String(record.place??record.PLACE??'').padStart(5,'0');if(st.trim()&&pl.trim())key=`US:PLACE:${st}${pl}`;break}case'ZCTA':{const z=String(record['zip code tabulation area']??record.ZCTA5??record.zcta??'').padStart(5,'0');if(z.trim())key=`US:ZCTA:${z}`;break}case'POSTAL_CODE':{const z=String(record.ZIPCODE??record['zip code']??record.zip??'').padStart(5,'0');if(z.trim())key=`US:ZIP:${z}`;break}case'MSA':{const g=String(record.GeoFIPS??record.geo_fips??'').replace(/[^0-9]/g,'');if(g)key=`US:CBSA:${g}`;break}}
 if(!key)return null;
 const sourceGEOID=key.startsWith('US:PLACE:')?key.slice('US:PLACE:'.length):'';
 const crosswalk=crosswalks.find(x=>x.sourceKey===source?.sourceKey&&x.sourceVintage===source?.sourceVintage&&x.geography===scope&&x.sourceGEOID===sourceGEOID);
 return crosswalk?.targetCanonicalKey??key;
}
export async function resolveLocation(c:PoolClient,scope:string,record:any,source?:{sourceKey:string;sourceVintage:string},crosswalks:GeographyCrosswalk[]=[]):Promise<string|null>{
 const key=canonicalLocationKey(scope,record,source,crosswalks);
 if(!key)return null;
 const q=await c.query<{location_id:string}>(`SELECT location_id::text FROM zsl.certified_canonical_locations WHERE canonical_key=$1`,[key]);return q.rows[0]?.location_id??null;
}

/** Resolve an entire certified release in one query instead of one remote round trip per row. */
export async function resolveLocations(c:PoolClient,scope:string,rows:any[],source?:{sourceKey:string;sourceVintage:string},crosswalks:GeographyCrosswalk[]=[]):Promise<Map<string,string>>{
 const keysByRecord=new Map<string,string>();
 for(const row of rows){const key=canonicalLocationKey(scope,row.record,source,crosswalks);if(key)keysByRecord.set(row.record_id,key)}
 const keys=[...new Set(keysByRecord.values())];if(keys.length===0)return new Map();
 const locations=(await c.query<{canonical_key:string;location_id:string}>(`SELECT canonical_key,location_id::text FROM zsl.certified_canonical_locations WHERE canonical_key=ANY($1::text[])`,[keys])).rows;
 const byKey=new Map(locations.map(x=>[x.canonical_key,x.location_id]));
 return new Map([...keysByRecord].flatMap(([recordId,key])=>{const locationId=byKey.get(key);return locationId?[[recordId,locationId] as [string,string]]:[]}));
}
