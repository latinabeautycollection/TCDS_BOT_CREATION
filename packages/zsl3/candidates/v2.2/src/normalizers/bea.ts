import type{PoolClient}from'pg';import{certifiedRows,insertFact}from'./facts.js';import{resolveLocation}from'./geography.js';import{sha256Canonical}from'../core/hash.js';
export async function normalizeBea(c:PoolClient,run:string):Promise<number>{
 let n=0;const binds=(await c.query<any>(`SELECT * FROM zsl.zsl3_source_bindings WHERE build_run_id=$1 AND source_dataset='BEA_RPP'`,[run])).rows;
 for(const b of binds){for(const raw of await certifiedRows(c,b)){
   const geoCode=String(raw.record.GeoFIPS??'').replace(/"/g,'').trim();
   const geoName=String(raw.record.GeoName??'').trim()||null;
   let loc=await resolveLocation(c,b.source_geography,raw.record);
   if(b.source_geography==='MSA'){
     let status='UNRESOLVED',reason='NO_CANONICAL_LOCATION',auth:any=null;
     if(loc){auth=(await c.query<any>(`SELECT cb.area_code_kind,cb.name_authority_status FROM zsl.cbsa_metros cb WHERE cb.location_id=$1`,[loc])).rows[0];
       if(auth?.area_code_kind==='CBSA'&&auth?.name_authority_status==='AUTHORITATIVE'){status='MAPPED_AUTHORITATIVE_CBSA';reason='AUTHORITATIVE_CBSA'}
       else if(auth?.area_code_kind==='METROPOLITAN_DIVISION'&&auth?.name_authority_status==='AUTHORITATIVE'){status='MAPPED_AUTHORITATIVE_METDIV';reason='AUTHORITATIVE_METDIV'}
       else{status='PENDING_ZSL2_AUTHORITY';reason='ZSL2_METRO_AUTHORITY_PENDING'}
     }
     const ev={geoCode,geoName,status,reason,resolvedLocationId:loc,areaCodeKind:auth?.area_code_kind??null,nameAuthorityStatus:auth?.name_authority_status??null};
     await c.query(`INSERT INTO zsl.zsl3_bea_msa_reconciliation(build_run_id,source_binding_id,raw_record_id,raw_record_sha256,bea_geography_code,bea_geography_name,mapping_status,resolved_location_id,reason_code,evidence,evidence_sha256)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11)`,
       [run,b.source_binding_id,raw.record_id,raw.record_sha256,geoCode,geoName,status,loc,reason,JSON.stringify(ev),sha256Canonical(ev)]);
     if(status!=='MAPPED_AUTHORITATIVE_CBSA'&&status!=='MAPPED_AUTHORITATIVE_METDIV')continue;
   }
   if(!loc)continue;
   const val=Number(String(raw.record.DataValue??raw.record.value??'').replace(/,/g,''));
   if(!Number.isFinite(val)||val<=0)continue;
   const fid=await insertFact(c,{run,locationId:loc,featureCode:'regional_price_parity',numericValue:val,unit:'INDEX_US_100',
     sourceRole:'BEA_RPP',binding:b,raw,sourceVariableCode:String(raw.record.LineCode??'')});
   await c.query(`INSERT INTO zsl.zsl3_regional_price_parity_facts(fact_id,year,bea_geography_identifier,bea_geography_kind,table_name,line_code,rpp,msa_mapping_status)
     VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,
     [fid,Number(raw.record.TimePeriod??b.source_year),geoCode,b.source_geography==='MSA'?'MSA':'STATE',
      String(raw.record.TableName??'RPP'),String(raw.record.LineCode??''),val,b.source_geography==='MSA'?'AUTHORITATIVE':'NOT_APPLICABLE']);
   n++;
 }}
 return n;
}
