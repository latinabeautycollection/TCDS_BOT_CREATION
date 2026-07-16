import { z } from 'zod';
import { cleanText, parseMoney } from './util.js';
const categorySchema=z.object({name:z.string().optional(),url:z.string().url().optional()}).passthrough();
const anyObj=z.record(z.unknown());
export const staplesRecordSchema=z.object({
  url:z.string().url(), item_id:z.union([z.string(),z.number()]).transform(String), variant_id:z.union([z.string(),z.number()]).transform(String).optional().nullable(),
  title:z.string().min(1), description:z.unknown().optional().nullable(), product_category:z.string().optional().nullable(), category_tree:z.array(categorySchema).optional().default([]),
  brand:z.string().optional().nullable(), image_url:z.string().url().optional().nullable(), price:z.unknown().optional().nullable(), sale_price:z.unknown().optional().nullable(),
  availability:z.string().optional().nullable(), availability_date:z.string().optional().nullable(), group_id:z.string().optional().nullable(), listing_has_variations:z.boolean().optional().default(false),
  variant_attributes:z.array(anyObj).optional().default([]), variants:z.array(anyObj).optional().default([]), store_name:z.string().optional().nullable(), seller_url:z.string().url().optional().nullable(),
  seller_privacy_policy:z.string().url().optional().nullable(), seller_tos:z.string().url().optional().nullable(), return_policy:z.string().url().optional().nullable(), return_window:z.coerce.number().int().nonnegative().optional().nullable(),
  target_countries:z.array(z.string()).optional().default([]), store_country:z.string().optional().nullable(), category_urls:z.array(z.string().url()).optional().default([]),
  star_rating:z.coerce.number().min(0).max(5).optional().nullable(), review_count:z.coerce.number().int().nonnegative().optional().nullable(), reviews:z.unknown().optional().nullable(),
  additional_image_urls:z.array(z.string().url()).optional().default([]), mpn:z.string().optional().nullable()
}).passthrough();
export type StaplesRecord=z.infer<typeof staplesRecordSchema>;
export function normalizeStaples(r:StaplesRecord){
  const regular=parseMoney(r.price), sale=parseMoney(r.sale_price), effective=sale??regular;
  if(effective===null) throw new Error('STAPLES_PRICE_MISSING');
  const availabilityText=(r.availability??'unknown').toLowerCase();
  const availabilityDb=availabilityText==='in_stock'?'in_stock':availabilityText==='out_of_stock'?'out_of_stock':availabilityText==='limited_stock'?'limited_stock':availabilityText==='preorder'?'preorder':'unknown';
  const available=availabilityDb==='in_stock';
  const images=[r.image_url,...r.additional_image_urls].filter((x):x is string=>Boolean(x));
  const category=r.product_category??(r.category_tree.map(x=>x.name).filter(Boolean).join(' > ')||null);
  return {itemId:r.item_id,variantId:r.variant_id??r.item_id,title:r.title,description:cleanText(r.description),brand:r.brand??null,mpn:r.mpn??null,regular,sale,effective,currency:'USD',available,availability:r.availability??'unknown',availabilityDb,availabilityDate:r.availability_date??null,category,image:images[0]??null,images:[...new Set(images)],rating:r.star_rating??null,reviewCount:r.review_count??null};
}
