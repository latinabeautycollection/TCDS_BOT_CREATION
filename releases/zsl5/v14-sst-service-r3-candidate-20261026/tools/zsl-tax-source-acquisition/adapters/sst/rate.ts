import {createHash} from 'node:crypto';
import {parse} from 'csv-parse/sync';
import type {CanonicalTaxRecord,EvidenceContext,ParserAdapter} from '../types.js';

const states='AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY'.split(' ');
const fips='01 02 04 05 06 08 09 10 11 12 13 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 44 45 46 47 48 49 50 51 53 54 55 56'.split(' ');
const byFips=new Map(fips.map((v,i)=>[v,states[i]! ]));
function day(v:string):string {
  if(!/^\d{8}$/.test(v))throw new Error('SST_INVALID_DATE');
  const iso=v.slice(0,4)+'-'+v.slice(4,6)+'-'+v.slice(6,8);
  const d=new Date(iso+'T00:00:00Z');
  if(!Number.isFinite(d.getTime())||d.toISOString().slice(0,10)!==iso)throw new Error('SST_INVALID_DATE');
  return iso;
}
function rate(v:string,optional=false):string|null {
  if(optional&&v==='')return null;
  if(!/^(?:0|1)(?:\.\d+)?$|^\.\d+$/.test(v)||Number(v)>1)throw new Error('SST_INVALID_RATE');
  return v;
}
export const sstRateAdapter:ParserAdapter={
  adapterKey:'sst-nine-column-observation-v1.0.0',recordTypes:['STATE_RATE','LOCAL_RATE'],
  canParse:({sourceKey,filename})=>sourceKey==='sst_rate_boundary'&&/(?:^|--)[A-Z]{2}R\d{4}Q[1-4][A-Z]{3}\d{1,2}\.csv$/i.test(filename),
  async parse(bytes:Buffer,ctx:EvidenceContext,filename:string):Promise<CanonicalTaxRecord[]> {
    if(!this.canParse({sourceKey:ctx.sourceKey,filename}))throw new Error('SST_UNSUPPORTED_FORMAT');
    if(createHash('sha256').update(bytes).digest('hex')!==ctx.artifactSha256)throw new Error('SST_ARTIFACT_HASH_MISMATCH');
    if(!ctx.releaseId||ctx.releaseId==='UNBOUND_RELEASE')throw new Error('SST_BOUND_RELEASE_REQUIRED');
    const expected=filename.match(/([A-Z]{2})R\d{4}Q/i)![1]!.toUpperCase();
    const input=parse(bytes,{bom:true,skip_empty_lines:true,trim:true,columns:false,delimiter:',',relax_column_count:false}) as string[][];
    if(!input.length)throw new Error('SST_EMPTY_ARTIFACT');
    const seen=new Set<string>();
    return input.map((cells,line)=>{
      if(cells.length!==9)throw new Error('SST_EXPECTED_NINE_COLUMNS:'+String(line+1));
      const [stateFips,typeRaw,code,gi,ge,fi,fe,begin,end]=cells as [string,string,string,string,string,string,string,string,string];
      const state=byFips.get(stateFips);
      if(!state||state!==expected)throw new Error('SST_STATE_MISMATCH');
      if(!/^\d{1,2}$/.test(typeRaw)||!/^[A-Za-z0-9]{2,5}$/.test(code))throw new Error('SST_INVALID_JURISDICTION');
      const from=day(begin),to=day(end);
      if(from>to)throw new Error('SST_REVERSED_SOURCE_DATES');
      const family=typeRaw.padStart(2,'0')==='45'?'STATE_RATE':'LOCAL_RATE';
      const key=[family,state,typeRaw.padStart(2,'0'),code,begin,end].join(':');
      if(seen.has(key))throw new Error('SST_DUPLICATE_SOURCE_IDENTITY');
      seen.add(key);
      return {record_type:family,state_code:state,natural_key:key,source_key:ctx.sourceKey,
        source_release_id:ctx.releaseId,source_artifact_sha256:ctx.artifactSha256,authority_rank:ctx.authorityRank,
        published_at:null,effective_from:null,effective_to:null,retrieved_at:ctx.retrievedAt,
        parser_version:this.adapterKey,normalization_version:'sst-observation-envelope-v1',legal_citation:null,
        payload:{observation_format:'SST_NINE_COLUMN_RATE_OBSERVATION_V1',executable:false,
          state_fips:stateFips,jurisdiction_type_code_raw:typeRaw,jurisdiction_type_code:typeRaw.padStart(2,'0'),
          jurisdiction_code:code,rates:{general_intrastate:rate(gi),general_interstate:rate(ge),
            food_drug_intrastate:rate(fi,true),food_drug_interstate:rate(fe,true)},
          source_effective_from:from,source_effective_to:to,source_end_date_semantics:'UNINTERPRETED',
          source_line:line+1}};
    });
  }
};
