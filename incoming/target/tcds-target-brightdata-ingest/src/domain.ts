import { z } from 'zod'; import { cleanText, parseMoney } from './util.js';
const anyObj=z.record(z.unknown());
const objectArray=z.array(anyObj).nullish().transform(value=>value??[]);
const stringArray=z.array(z.string()).nullish().transform(value=>value??[]);
export const targetRecordSchema=z.object({
 url:z.string().url(), product_id:z.union([z.string(),z.number()]).transform(String), title:z.string().min(1), product_description:z.unknown().optional().nullable(),
 rating:z.coerce.number().min(0).max(5).optional().nullable(), reviews_count:z.coerce.number().int().nonnegative().optional().nullable(), initial_price:z.unknown().optional().nullable(),
 final_price:z.unknown().optional().nullable(), sale_price:z.unknown().optional().nullable(), price:z.unknown().optional().nullable(), currency:z.string().optional().default('USD'), images:stringArray,
 breadcrumbs:objectArray, seller_name:z.string().optional().nullable(), offers:z.unknown().optional().nullable(), product_specifications:objectArray,
 shipping_returns_policy:stringArray, related_categories:objectArray, amount_of_stars:objectArray,
 recommendations:objectArray, variations:objectArray, what_customers_said:objectArray, review_images:stringArray,
 upc:z.string().optional().nullable(), product_brand:z.string().optional().nullable(), item_number:z.string().optional().nullable(), retailer:z.string().optional().nullable(), price_range:z.unknown().optional().nullable(),
 is_available:z.boolean().optional().nullable(), availability_text:z.string().optional().nullable(), promotion_fulltext:z.string().optional().nullable(), tcin_id:z.string().optional().nullable(), upc_normalization:z.string().optional().nullable(),
 breadcrumb_text:z.string().optional().nullable(), manufacturer_description:z.unknown().optional().nullable(), product_variant:objectArray, customer_reviews:objectArray,
 image_url:z.string().optional().nullable(), availability:z.string().optional().nullable(), availability_date:z.string().optional().nullable(), group_id:z.string().optional().nullable(), listing_has_variations:z.boolean().optional().default(false),
 variant_attributes:objectArray, variants:objectArray, category_urls:stringArray, seller_url:z.string().optional().nullable(),
 seller_privacy_policy:z.string().optional().nullable(), seller_tos:z.string().optional().nullable(), return_policy:z.string().optional().nullable(), return_window:z.coerce.number().int().nonnegative().optional().nullable(),
 target_countries:stringArray, store_country:z.string().optional().nullable(), discount:z.unknown().optional().nullable(), fit_and_sytle:stringArray,
 q:z.unknown().optional(), 'q&a':z.unknown().optional().nullable(), summary_of_reviews:z.unknown().optional().nullable(), reviews_related:z.unknown().optional().nullable(), find_alternative:z.unknown().optional().nullable()
}).passthrough();
export type TargetRecord=z.infer<typeof targetRecordSchema>;
export function normalizeTarget(r:TargetRecord){ const regular=parseMoney(r.initial_price)??parseMoney(r.price); const sale=parseMoney(r.sale_price); const final=parseMoney(r.final_price); const effective=final??sale??regular; if(effective===null) throw new Error('TARGET_PRICE_MISSING'); const availabilityText=r.availability??r.availability_text??null;const availability=normalizeAvailability(availabilityText,r.is_available);return {productId:r.product_id,tcin:r.tcin_id??r.product_id,upc:r.upc_normalization??r.upc??null,dpci:findSpec(r.product_specifications,'Item Number (DPCI)'),title:r.title,description:cleanText(r.product_description),brand:r.product_brand??null,regular,sale,final,effective,currency:(r.currency||'USD').slice(0,3).toUpperCase(),available:r.is_available??null,availability,availabilityText:availabilityText??'unknown',image:r.image_url??r.images[0]??null,category:r.breadcrumb_text??r.breadcrumbs.map(x=>String(x.name??'')).filter(Boolean).join(' > '),rating:r.rating??null,reviewsCount:r.reviews_count??null}; }
function normalizeAvailability(value:string|null,available:boolean|null|undefined){const v=(value??'').trim().toLowerCase().replace(/[\s-]+/g,'_');if(['in_stock','available'].includes(v))return 'in_stock';if(['out_of_stock','unavailable'].includes(v))return 'out_of_stock';if(['limited_stock','limited'].includes(v))return 'limited_stock';if(['preorder','pre_order'].includes(v))return 'preorder';if(available===true)return 'in_stock';if(available===false)return 'out_of_stock';return 'unknown';}
function findSpec(specs:Record<string,unknown>[],name:string){const x=specs.find(s=>String(s.specification_name??s.name).toLowerCase()===name.toLowerCase());return x?String(x.specification_value??x.value??'')||null:null;}
