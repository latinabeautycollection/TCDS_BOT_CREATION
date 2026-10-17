import { join } from "node:path";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { spawn } from "node:child_process";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createInterface } from "node:readline";
import type { ZslSourceAdapter,SourceRelease,RetrievedArtifact,ArtifactValidation,RawSourceRecord,RecordValidation,IngestContext,ReconciliationResult,ValidationIssue } from "../core/types.js";
import { loadPolicy } from "../core/policy.js";
import { downloadToFile } from "../core/http.js";
import { sha256Canonical } from "../core/hash.js";
import { inspectZip } from "../core/archive.js";
import { detectDelimiter, parseCsvStream, parseDelimitedLine } from "../core/delimited.js";
import { validateRequired } from "./common.js";

type FreightSource = "BTS_FAF6_ZONE_LOOKUP" | "BTS_SCTG_METADATA" | "CENSUS_CBP";
type Definition = { sourceKey: FreightSource; releaseLabel: string; required: string[]; aliases: Record<string,string[]>; naturalKey: (record:Record<string,unknown>, ordinal:number)=>string };

const definitions:Record<FreightSource,Definition> = {
  BTS_FAF6_ZONE_LOOKUP: {sourceKey:"BTS_FAF6_ZONE_LOOKUP",releaseLabel:"BTS FAF6 Zone Lookup",required:["faf6_zone","name"],aliases:{faf6_zone:["faf6_zone","FAF6","faf_zone","zone","dms_orig"],name:["name","NAME","label","FAF6_NAME"],state_fips:["state_fips","STATEFP","state"],cfs22:["cfs22","CFS22","cfs_area"],cbsa:["cbsa","CBSA","cbsa_code"]},naturalKey:(r,n)=>String(r.faf6_zone??n)},
  BTS_SCTG_METADATA: {sourceKey:"BTS_SCTG_METADATA",releaseLabel:"BTS SCTG Metadata",required:["code","label"],aliases:{code:["code","SCTG2","sctg2","natural_key"],label:["label","description","DESCRIPTION","sctg_description"]},naturalKey:(r,n)=>String(r.code??n)},
  CENSUS_CBP: {sourceKey:"CENSUS_CBP",releaseLabel:"Census County Business Patterns",required:["GEO_ID","NAICS2017"],aliases:{GEO_ID:["GEO_ID","GEOID"],STATE:["STATE","state","fipstate"],COUNTY:["COUNTY","county","fipscty"],NAICS2017:["NAICS2017","NAICS2022","NAICS","naics"],ESTAB:["ESTAB","est"],EMP:["EMP","emp"],PAYANN:["PAYANN","ap"]},naturalKey:(r,n)=>[r.GEO_ID,r.NAICS2017].map(x=>String(x??"")).join(":")||String(n)}
};
const exec=promisify(execFile);
const SCTG_TWO_DIGIT_MEMBER="2_Digit_Codes/SCTG_2_Digit_Codes_1997.txt";

function decodeXml(value:string):string{return value.replace(/&(?:amp|lt|gt|quot|apos);/g,token=>({"&amp;":"&","&lt;":"<","&gt;":">","&quot;":"\"","&apos;":"'"})[token]!);}
function xmlText(fragment:string):string{return decodeXml([...fragment.matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)].map(match=>match[1]??"").join(""));}
function columnIndex(reference:string):number{let result=0;for(const char of reference.match(/[A-Z]+/)?.[0]??"")result=result*26+char.charCodeAt(0)-64;return result-1;}
async function unzipText(path:string,member:string):Promise<string>{const {stdout}=await exec("unzip",["-p",path,member],{maxBuffer:16*1024*1024});return stdout;}
async function readZoneWorkbook(path:string):Promise<string[][]>{
  const [sharedXml,sheetXml]=await Promise.all([unzipText(path,"xl/sharedStrings.xml"),unzipText(path,"xl/worksheets/sheet1.xml")]);
  const shared=[...sharedXml.matchAll(/<si\b[^>]*>([\s\S]*?)<\/si>/g)].map(match=>xmlText(match[1]??""));
  const rows:string[][]=[];
  for(const row of sheetXml.matchAll(/<row\b[^>]*>([\s\S]*?)<\/row>/g)){
    const values:string[]=[];
    for(const cell of (row[1]??"").matchAll(/<c\b([^>]*)>([\s\S]*?)<\/c>/g)){
      const reference=/\br="([A-Z]+)\d+"/.exec(cell[1]??"")?.[1];
      if(!reference)throw new Error("FAF_ZONE_WORKBOOK_CELL_REFERENCE_MISSING");
      const value=/<v>([\s\S]*?)<\/v>/.exec(cell[2]??"")?.[1]??"";
      const sharedCell=/\bt="s"/.test(cell[1]??"");
      const index=columnIndex(reference); if(index<0)throw new Error("FAF_ZONE_WORKBOOK_COLUMN_INVALID");
      values[index]=sharedCell?(shared[Number(value)]??""):decodeXml(value);
    }
    if(values.some(value=>value!==undefined))rows.push(values.map(value=>value??""));
  }
  if(rows.length<2)throw new Error("FAF_ZONE_WORKBOOK_ROWS_MISSING");
  return rows;
}
async function* parseTabDelimited(stream:NodeJS.ReadableStream):AsyncIterable<string[]>{
  const rl=createInterface({input:stream,crlfDelay:Infinity}); let started=false; let delimiter:string|undefined;
  for await(const line of rl){if(!line.trim())continue;const candidateDelimiter=delimiter??detectDelimiter(line);const row=parseDelimitedLine(line,candidateDelimiter);
    if(!started){if(row.length===2&&row[0]?.trim().toLowerCase()==="code"&&row[1]?.trim().toLowerCase()==="description"){started=true;delimiter=candidateDelimiter;}else continue;}
    yield row;
  }
  if(!started)throw new Error("SCTG_HEADER_MISSING");
}
async function* arrayRows(rows:string[][]):AsyncIterable<string[]>{for(const row of rows)yield row;}

function canonicalize(headers:string[], row:string[], aliases:Record<string,string[]>):Record<string,unknown>{
  const raw:Record<string,unknown>={};
  headers.forEach((header,index)=>raw[header]=row[index]??"");
  const lower=new Map(headers.map(header=>[header.toLowerCase(),header]));
  for(const [canonical,names] of Object.entries(aliases)){
    const actual=names.map(name=>lower.get(name.toLowerCase())).find((name):name is string=>Boolean(name));
    if(actual) raw[canonical]=raw[actual];
  }
  return raw;
}

function fips(value:unknown,width:number):string|undefined{const text=String(value??"").trim();return /^\d{1,}$/.test(text)&&text.length<=width?text.padStart(width,"0"):undefined;}
export function deriveCbpCountyGeoId(record:Record<string,unknown>):string|undefined{
  const existing=String(record.GEO_ID??"").trim();if(existing)return existing;
  const state=fips(record.STATE,2),county=fips(record.COUNTY,3);
  return state&&county?`0500000US${state}${county}`:undefined;
}

export class FreightReferenceAdapter implements ZslSourceAdapter {
  readonly adapterVersion="2.1.1";
  readonly sourceKey:FreightSource;
  private readonly definition:Definition;
  constructor(sourceKey:FreightSource, private readonly releaseKey:string, private readonly sourceYear:number, private readonly governedUrl:string){
    this.sourceKey=sourceKey;this.definition=definitions[sourceKey];
    if(!releaseKey.trim()) throw new Error("FREIGHT_RELEASE_KEY_REQUIRED");
    const earliestYear=sourceKey==="BTS_SCTG_METADATA"?1997:2000;
    if(!Number.isInteger(sourceYear)||sourceYear<earliestYear||sourceYear>2200) throw new Error("FREIGHT_SOURCE_YEAR_INVALID");
    if(!governedUrl) throw new Error("FREIGHT_GOVERNED_URL_REQUIRED");
  }
  async discoverRelease():Promise<SourceRelease>{return {sourceKey:this.sourceKey,releaseKey:this.releaseKey,releaseLabel:`${this.definition.releaseLabel} ${this.releaseKey}`,sourceYear:this.sourceYear,discoveredAt:new Date().toISOString(),metadata:{releaseKey:this.releaseKey,sourceYear:this.sourceYear,governedUrl:new URL(this.governedUrl).origin}}}
  async retrieve(release:SourceRelease):Promise<RetrievedArtifact>{const {doc}=await loadPolicy();const policy=doc.sources[this.sourceKey]!;const directory=await mkdtemp(join(tmpdir(),"zsl-freight-reference-"));const extension=this.sourceKey==="BTS_FAF6_ZONE_LOOKUP"?"xlsx":"zip";const localPath=join(directory,`${this.sourceKey}_${release.releaseKey.replace(/[^A-Za-z0-9._-]/g,"_")}.${extension}`);const downloaded=await downloadToFile(this.governedUrl,{headers:{"user-agent":"TCDS-ZSL1/2.1.1",Accept:this.sourceKey==="BTS_FAF6_ZONE_LOOKUP"?"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/octet-stream":"application/zip,application/octet-stream"}},localPath,policy);return {sourceKey:this.sourceKey,releaseKey:release.releaseKey,fileName:localPath.split("/").pop()!,localPath,sourceUrl:this.governedUrl,byteCount:downloaded.byteCount,sha256:downloaded.sha256,retrievedAt:new Date().toISOString(),...(downloaded.contentType?{contentType:downloaded.contentType}:{})}}
  private async member(path:string){const {doc}=await loadPolicy();const members=await inspectZip(path,doc.sources[this.sourceKey]!);if(this.sourceKey==="BTS_SCTG_METADATA"){const member=members.find(candidate=>candidate.name===SCTG_TWO_DIGIT_MEMBER);if(!member)throw new Error("SCTG_TWO_DIGIT_MEMBER_MISSING");return member;}const delimited=members.filter(member=>/\.(?:csv|txt)$/i.test(member.name));if(delimited.length!==1) throw new Error(`FREIGHT_EXPECTED_SINGLE_DELIMITED_MEMBER:${this.sourceKey}:${delimited.length}`);return delimited[0]!}
  private stream(path:string, member:string){const child=spawn("unzip",["-p",path,member],{stdio:["ignore","pipe","pipe"]});let stderr="";child.stderr.setEncoding("utf8");child.stderr.on("data",(chunk:string)=>stderr+=chunk);child.once("close",code=>{if(code!==0)child.stdout.destroy(new Error(`FREIGHT_UNZIP_FAILED:${code}:${stderr.slice(0,1000)}`))});return child.stdout}
  private rows(path:string,member:string):AsyncIterable<string[]>{return this.sourceKey==="BTS_SCTG_METADATA"?parseTabDelimited(this.stream(path,member)):parseCsvStream(this.stream(path,member));}
  async validateArtifact(artifact:RetrievedArtifact):Promise<ArtifactValidation>{const zone=this.sourceKey==="BTS_FAF6_ZONE_LOOKUP"?await readZoneWorkbook(artifact.localPath):undefined;const member=zone?{name:"xl/worksheets/sheet1.xml",expandedBytes:0,compressedBytes:0}:await this.member(artifact.localPath);const iterator=(zone?arrayRows(zone):this.rows(artifact.localPath,member.name))[Symbol.asyncIterator]();const headers=(await iterator.next()).value?.map((value:string)=>value.trim()) as string[]|undefined;const issues:ValidationIssue[]=[];if(!headers?.length) issues.push({code:"FREIGHT_HEADER_MISSING",message:"Delimited header missing",fatal:true});
    const available=new Set((headers??[]).map(header=>header.toLowerCase()));const canDeriveCbpGeoId=this.sourceKey==="CENSUS_CBP"&&available.has("fipstate")&&available.has("fipscty");
    for(const required of this.definition.required){const aliases=this.definition.aliases[required]??[required];if(required==="GEO_ID"&&canDeriveCbpGeoId)continue;if(!aliases.some(alias=>available.has(alias.toLowerCase()))) issues.push({code:"FREIGHT_REQUIRED_HEADER_MISSING",message:required,fatal:true,field:required});}
    return {valid:issues.every(issue=>!issue.fatal),issues,schemaSha256:sha256Canonical({sourceKey:this.sourceKey,releaseKey:this.releaseKey,member:member.name,headers:headers??[]}),evidence:{member:member.name,headers:headers??[],expandedBytes:member.expandedBytes,compressedBytes:member.compressedBytes}};
  }
  async *parse(artifact:RetrievedArtifact):AsyncIterable<RawSourceRecord>{const zone=this.sourceKey==="BTS_FAF6_ZONE_LOOKUP"?await readZoneWorkbook(artifact.localPath):undefined;const member=zone?undefined:await this.member(artifact.localPath);let headers:string[]|undefined;let ordinal=0;for await(const row of zone?arrayRows(zone):this.rows(artifact.localPath,member!.name)){if(!headers){headers=row.map(value=>value.trim());continue;}ordinal++;if(row.length!==headers.length) throw new Error(`FREIGHT_COLUMN_COUNT_MISMATCH:${this.sourceKey}:${ordinal}:${row.length}:${headers.length}`);const record=canonicalize(headers,row,this.definition.aliases);if(this.sourceKey==="CENSUS_CBP")record.GEO_ID=deriveCbpCountyGeoId(record);yield {naturalKey:this.definition.naturalKey(record,ordinal),record};}}
  validateRecord(record:RawSourceRecord):RecordValidation{const base=validateRequired(record,this.definition.required);const issues=[...base.issues];if(this.sourceKey==="BTS_FAF6_ZONE_LOOKUP"&&!/^[0-9]{3,6}$/.test(String(record.record.faf6_zone??"")))issues.push({code:"FAF_ZONE_INVALID",message:String(record.record.faf6_zone??""),fatal:true,field:"faf6_zone"});if(this.sourceKey==="BTS_SCTG_METADATA"&&!/^[0-9]{2}$/.test(String(record.record.code??"")))issues.push({code:"SCTG_CODE_INVALID",message:String(record.record.code??""),fatal:true,field:"code"});if(this.sourceKey==="CENSUS_CBP"&&!/^0500000US\d{5}$/.test(String(record.record.GEO_ID??"")))issues.push({code:"CBP_COUNTY_GEOID_INVALID",message:String(record.record.GEO_ID??""),fatal:true,field:"GEO_ID"});return {valid:issues.every(issue=>!issue.fatal),issues};}
  async reconcile(_context:IngestContext):Promise<ReconciliationResult>{return {ok:true,parsedCount:0,loadedMembershipCount:0,distinctRecordCount:0,issues:[]};}
}
