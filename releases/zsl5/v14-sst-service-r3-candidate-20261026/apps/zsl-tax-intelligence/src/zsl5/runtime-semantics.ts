import type {PurchaseChannel,QuoteLine} from '../core/types.js';
export type RuntimeFact={fact_id:string;family:string;state_code:string;tax_jurisdiction_code:string|null;tax_product_class:string|null;tax_product_subclass:string|null;purchase_channel:string|null;priority:number;predicate_document:any;value_document:any};
export const val=(f:RuntimeFact,k:string)=>f.value_document?.[k];
export function matchesProduct(f:RuntimeFact,line:QuoteLine){const cls=line.taxProductClass,sub=line.taxProductSubclass;return (!f.tax_product_class||f.tax_product_class===cls)&&(!f.tax_product_subclass||f.tax_product_subclass===sub)}
export function appliesJurisdiction(f:RuntimeFact,jurisdictions:string[]){return !f.tax_jurisdiction_code||jurisdictions.includes(f.tax_jurisdiction_code)}
export function appliesChannel(f:RuntimeFact,ch:PurchaseChannel){const pcs=val(f,'purchase_channels');return (!f.purchase_channel||f.purchase_channel===ch)&&(!Array.isArray(pcs)||pcs.includes(ch))}
export function enumRequired(v:unknown,allowed:string[],code:string){if(typeof v!=='string'||!allowed.includes(v))throw new Error(code+':'+String(v));return v}
export function boolRequirement(v:unknown,code:string){if(v==='REQUIRED')return true;if(v==='NOT_REQUIRED')return false;throw new Error(code+':'+String(v))}
export function assertIsoInstant(v:string,code:string){const d=new Date(v);if(!v||Number.isNaN(d.getTime())||!/[zZ]|[+-]\d\d:\d\d$/.test(v))throw new Error(code);return d}
