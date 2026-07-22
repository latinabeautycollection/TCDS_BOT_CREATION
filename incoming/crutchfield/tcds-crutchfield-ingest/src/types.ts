import { z } from 'zod';
const ns=z.string().nullable().optional();
const na=<T extends z.ZodTypeAny>(s:T)=>z.preprocess(v=>v==null?[]:v,z.array(s));
const nn=z.union([z.number(),z.string()]).nullable().optional();
export const CrutchfieldRecordSchema=z.object({
 url:z.string().url().refine(v=>new URL(v).hostname.toLowerCase().endsWith('crutchfield.com'),'Product URL must belong to crutchfield.com'),
 item_id:z.union([z.string(),z.number()]).transform(String),variant_id:z.union([z.string(),z.number()]).nullable().optional().transform(v=>v==null?null:String(v)),
 title:z.string().trim().min(1),description:ns,product_category:ns,category_tree:na(z.object({name:z.string(),url:z.string().url().nullable().optional()})),brand:ns,
 image_url:z.string().url().nullable().optional(),additional_image_urls:na(z.string().url()),price:nn,sale_price:nn,availability:ns,availability_date:ns,
 group_id:z.union([z.string(),z.number()]).nullable().optional().transform(v=>v==null?null:String(v)),listing_has_variations:z.boolean().nullable().optional().transform(v=>v??false),
 variant_attributes:na(z.unknown()),variants:na(z.unknown()),store_name:ns,seller_url:z.string().url().nullable().optional(),seller_privacy_policy:z.string().url().nullable().optional(),seller_tos:z.string().url().nullable().optional(),return_policy:z.string().url().nullable().optional(),return_window:z.number().int().nonnegative().nullable().optional(),target_countries:na(z.string()),store_country:ns,category_urls:na(z.string().url()),star_rating:z.number().min(0).max(5).nullable().optional(),review_count:z.number().int().nonnegative().nullable().optional(),reviews:na(z.unknown()),gtin:ns,mpn:ns
}).passthrough();
export type CrutchfieldRecord=z.infer<typeof CrutchfieldRecordSchema>;
export type SnapshotStatus={snapshot_id?:string;id?:string;status?:string;dataset_id?:string;error?:unknown};
