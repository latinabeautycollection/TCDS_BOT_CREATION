import { z } from 'zod';
const nullableString=z.string().nullable().optional();
const nullableArray=<T extends z.ZodTypeAny>(item:T)=>z.array(item).nullish().transform(value=>value??[]);
export const NeweggRecordSchema=z.object({
  url:z.string().url(), item_id:z.union([z.string(),z.number()]).transform(String), variant_id:z.union([z.string(),z.number()]).nullable().optional().transform(v=>v==null?null:String(v)),
  gtin:nullableString, mpn:nullableString, title:z.string().min(1), description:nullableString, product_category:nullableString,
  category_tree:nullableArray(z.object({name:z.string(),url:z.string().url().nullable().optional()})), brand:nullableString,
  image_url:nullableString, additional_image_urls:nullableArray(z.string().url()), price:z.union([z.string(),z.number()]).nullable().optional(), sale_price:z.union([z.string(),z.number()]).nullable().optional(),
  availability:nullableString, availability_date:nullableString, group_id:z.union([z.string(),z.number()]).nullable().optional().transform(v=>v==null?null:String(v)), listing_has_variations:z.boolean().default(false),
  variant_attributes:nullableArray(z.unknown()), variants:nullableArray(z.unknown()), store_name:nullableString, seller_url:nullableString,
  seller_privacy_policy:nullableString, seller_tos:nullableString, return_policy:nullableString, return_window:z.number().int().nullable().optional(),
  review_count:z.number().int().nonnegative().nullable().optional(), star_rating:z.number().min(0).max(5).nullable().optional(), reviews:nullableArray(z.unknown()),
  target_countries:nullableArray(z.string()), store_country:nullableString, category_urls:nullableArray(z.string().url())
}).passthrough();
export type NeweggRecord=z.infer<typeof NeweggRecordSchema>;
export type SnapshotStatus={snapshot_id?:string;id?:string;status?:string;dataset_id?:string;error?:unknown};
