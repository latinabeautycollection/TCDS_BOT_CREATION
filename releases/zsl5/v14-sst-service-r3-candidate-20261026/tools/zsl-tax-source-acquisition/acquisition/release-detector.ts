export interface ReleaseHint { release_key:string; release_label:string; source_year:number|null; source_quarter:number|null; publication_date:string|null; effective_from:string|null; correction:boolean; }
export function detectRelease(filename:string,lastModified?:string|null):ReleaseHint{
  const upper=filename.toUpperCase();const y=upper.match(/20\d{2}/)?.[0];const q=upper.match(/Q([1-4])/i)?.[1];const date=lastModified?new Date(lastModified):null;
  const year=y?Number(y):(date&&!Number.isNaN(date.valueOf())?date.getUTCFullYear():null);
  const quarter=q?Number(q):(date&&!Number.isNaN(date.valueOf())?Math.floor(date.getUTCMonth()/3)+1:null);
  const correction=/(CORR|CORRECT|REVISED|UPDATE)/i.test(filename);
  const key=[year??'UNKNOWN',quarter?`Q${quarter}`:'',correction?'CORRECTION':'BASE',filename].filter(Boolean).join(':');
  return {release_key:key,release_label:key,source_year:year,source_quarter:quarter,publication_date:date&&!Number.isNaN(date.valueOf())?date.toISOString():null,effective_from:null,correction};
}
