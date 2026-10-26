import { parse } from 'csv-parse/sync';
export function parseDelimited(bytes:Buffer,delimiter?:string){const text=bytes.toString('utf8').replace(/^\uFEFF/,'');const d=delimiter??(text.includes('\t')?'\t':'|');return parse(text,{columns:true,skip_empty_lines:true,relax_column_count:true,trim:true,delimiter:d});}
