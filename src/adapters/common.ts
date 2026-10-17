import type { RawSourceRecord, RecordValidation, ValidationIssue } from "../core/types.js";

export function validateRequired(record:RawSourceRecord, fields:string[]):RecordValidation {
  const issues:ValidationIssue[]=[];
  for(const f of fields){
    const v=record.record[f];
    if(v===undefined || v===null || String(v).trim()===""){
      issues.push({code:"REQUIRED_FIELD_MISSING",message:`Required field missing: ${f}`,fatal:true,field:f});
    }
  }
  return {valid:issues.every(i=>!i.fatal),issues};
}
