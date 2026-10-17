import { join } from "node:path";import { mkdtemp,readFile } from "node:fs/promises";import { tmpdir } from "node:os";import type { ZslSourceAdapter,SourceRelease,RetrievedArtifact,ArtifactValidation,RawSourceRecord,RecordValidation,IngestContext,ReconciliationResult,ValidationIssue } from "../core/types.js";import { loadPolicy } from "../core/policy.js";import { downloadToFile,fetchWithRetry } from "../core/http.js";import { sha256Canonical } from "../core/hash.js";

function beaGeoFips(row:any):string{
  return String(row?.GeoFIPS ?? row?.GeoFips ?? '').trim();
}

function beaLineCode(row:any,tableName:string):string{
  const direct=String(row?.LineCode ?? '').trim();
  if(direct)return direct;

  const code=String(row?.Code ?? '').trim();
  const prefix=`${tableName}-`;

  return code.startsWith(prefix)
    ? code.slice(prefix.length)
    : '';
}

export class BeaRegionalRppAdapter implements ZslSourceAdapter{readonly sourceKey='BEA_REGIONAL_RPP';readonly adapterVersion='2.1.0';constructor(private readonly year:number,private readonly tableName:string,private readonly lineCode:string,private readonly geoFips:'STATE'|'MSA'){if(!/^\d{4}$/.test(String(year)))throw new Error('BEA_YEAR_INVALID')}
 async discoverRelease():Promise<SourceRelease>{return{sourceKey:this.sourceKey,releaseKey:`${this.year}:${this.tableName}:${this.geoFips}:${this.lineCode}`,releaseLabel:`BEA RPP ${this.year} ${this.tableName} ${this.geoFips}`,sourceYear:this.year,discoveredAt:new Date().toISOString(),metadata:{tableName:this.tableName,lineCode:this.lineCode,geoFips:this.geoFips,dataset:'Regional'}}}
 async retrieve(rel:SourceRelease):Promise<RetrievedArtifact>{const key=process.env.BEA_API_KEY;if(!key)throw new Error('BEA_API_KEY_REQUIRED');const {doc}=await loadPolicy();const p=doc.sources[this.sourceKey]!;const base='https://apps.bea.gov/api/data';const u=new URL(base);for(const [k,v]of Object.entries({UserID:key,method:'GetData',datasetname:'Regional',TableName:this.tableName,LineCode:this.lineCode,GeoFIPS:this.geoFips,Year:String(this.year),ResultFormat:'JSON'}))u.searchParams.set(k,v);const d=await mkdtemp(join(tmpdir(),'zsl-bea-'));const path=join(d,`${rel.releaseKey.replaceAll(':','_')}.json`);const m=await downloadToFile(u.toString(),{headers:{Accept:'application/json','user-agent':'TCDS-ZSL1/2.1'}},path,p);return{sourceKey:this.sourceKey,releaseKey:rel.releaseKey,fileName:path.split('/').pop()!,localPath:path,sourceUrl:base,byteCount:m.byteCount,sha256:m.sha256,retrievedAt:new Date().toISOString(),...(m.contentType?{contentType:m.contentType}:{})}}
 async validateArtifact(
  a:RetrievedArtifact
):Promise<ArtifactValidation>{
  const key=process.env.BEA_API_KEY;
  if(!key)throw new Error('BEA_API_KEY_REQUIRED');

  const {doc}=await loadPolicy();
  const p=doc.sources[this.sourceKey]!;
  const payload=JSON.parse(
    await readFile(a.localPath,'utf8')
  ) as any;
  const rows=payload?.BEAAPI?.Results?.Data;
  const issues:ValidationIssue[]=[];

  if(!Array.isArray(rows)||rows.length===0){
    issues.push({
      code:'BEA_DATA_MISSING',
      message:'Results.Data missing/empty',
      fatal:true
    });
  }

  if(Array.isArray(rows)){
    if(!rows.some((r:any)=>beaGeoFips(r))){
      issues.push({
        code:'BEA_FIELD_MISSING',
        message:'GeoFIPS or GeoFips',
        fatal:true,
        field:'GeoFIPS'
      });
    }

    if(!rows.some((r:any)=>beaLineCode(r,this.tableName))){
      issues.push({
        code:'BEA_FIELD_MISSING',
        message:'LineCode or Code',
        fatal:true,
        field:'LineCode'
      });
    }

    for(const f of ['GeoName','TimePeriod','DataValue']){
      if(!rows.some((r:any)=>r?.[f]!==undefined)){
        issues.push({
          code:'BEA_FIELD_MISSING',
          message:f,
          fatal:true,
          field:f
        });
      }
    }

    if(rows.some((r:any)=>
      String(r.TimePeriod??r.Year)!==String(this.year)
    )){
      issues.push({
        code:'BEA_YEAR_MISMATCH',
        message:'Unexpected TimePeriod',
        fatal:true
      });
    }

    if(rows.some((r:any)=>
      beaLineCode(r,this.tableName)!==String(this.lineCode)
    )){
      issues.push({
        code:'BEA_LINECODE_MISMATCH',
        message:'Unexpected LineCode or Code',
        fatal:true
      });
    }

    if(rows.some((r:any)=>
      !Number.isFinite(
        Number(String(r.DataValue??'').replaceAll(',',''))
      )
    )){
      issues.push({
        code:'BEA_NON_NUMERIC_RPP',
        message:'Non numeric RPP DataValue',
        fatal:true
      });
    }
  }

  const mu=new URL('https://apps.bea.gov/api/data');

  for(const [k,v] of Object.entries({
    UserID:key,
    method:'GetParameterValuesFiltered',
    datasetname:'Regional',
    TargetParameter:'TableName',
    ResultFormat:'JSON'
  }))mu.searchParams.set(k,v);

  const mr=await fetchWithRetry(
    mu.toString(),
    {
      headers:{
        Accept:'application/json',
        'user-agent':'TCDS-ZSL1/2.1'
      }
    },
    p
  );

  const meta=await mr.json() as any;
  const metaText=JSON.stringify(meta);

  if(!metaText.includes(this.tableName)){
    issues.push({
      code:'BEA_TABLE_METADATA_NOT_FOUND',
      message:this.tableName,
      fatal:true
    });
  }

  const metadataSha256=sha256Canonical(meta);

  return{
    valid:issues.every(x=>!x.fatal),
    issues,
    schemaSha256:sha256Canonical({
      table:this.tableName,
      lineCode:this.lineCode,
      geoFips:this.geoFips,
      year:this.year,
      metadataSha256
    }),
    evidence:{
      rowCount:Array.isArray(rows)?rows.length:0,
      metadataSha256,
      tableName:this.tableName,
      lineCode:this.lineCode,
      geoFips:this.geoFips
    }
  };
}
 async *parse(
  a:RetrievedArtifact
):AsyncIterable<RawSourceRecord>{
  const payload=JSON.parse(
    await readFile(a.localPath,'utf8')
  ) as any;

  for(const providerRecord of
    payload.BEAAPI.Results.Data as any[]
  ){
    const record={
      ...providerRecord,
      GeoFIPS:beaGeoFips(providerRecord),
      LineCode:beaLineCode(providerRecord,this.tableName)
    };

    yield{
      naturalKey:`${record.GeoFIPS}:${record.LineCode}:${record.TimePeriod??record.Year??''}`,
      record
    };
  }
}
 validateRecord(r:RawSourceRecord):RecordValidation{const issues:ValidationIssue[]=[];for(const f of ['GeoFIPS','GeoName','LineCode','TimePeriod','DataValue'])if(r.record[f]===undefined||String(r.record[f]).trim()==='')issues.push({code:'REQUIRED_FIELD_MISSING',message:f,fatal:true,field:f});const n=Number(String(r.record.DataValue??'').replaceAll(',',''));if(!Number.isFinite(n))issues.push({code:'BEA_NON_NUMERIC_RPP',message:String(r.record.DataValue),fatal:true,field:'DataValue'});return{valid:issues.every(x=>!x.fatal),issues}}
 async reconcile(_c:IngestContext):Promise<ReconciliationResult>{return{ok:true,parsedCount:0,loadedMembershipCount:0,distinctRecordCount:0,issues:[]}}
}
