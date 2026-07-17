import { z } from "zod";
import type { AdoramaRawRecord, NormalizedProduct } from "./types.js";
const rec=z.object({url:z.string().url(),item_id:z.coerce.string().min(1),variant_id:z.coerce.string().optional(),title:z.string().min(1)}).passthrough();
const s=(v:unknown)=>typeof v==='string'&&v.trim()?v.trim():null;
const n=(v:unknown)=>{if(typeof v==='number'&&Number.isFinite(v))return v;if(typeof v==='string'){const x=Number(v.replace(/[^0-9.-]/g,''));return Number.isFinite(x)?x:null;}return null};
const a=(v:unknown)=>Array.isArray(v)?v:[];
const sa=(v:unknown)=>a(v).filter((x):x is string=>typeof x==='string');
export function normalizeAdorama(input:AdoramaRawRecord):NormalizedProduct {
 const r=rec.parse(input); const image=s(r.image_url); const cleanImage=image?.includes('/undefined')?null:image;
 return {sourceUrl:r.url,itemId:String(r.item_id),variantId:String(r.variant_id??r.item_id),title:r.title.trim(),description:s(r.description),productCategory:s(r.product_category),categoryTree:a(r.category_tree),brand:s(r.brand),imageUrl:cleanImage,price:n(r.price),salePrice:n(r.sale_price),currency:'USD',availability:s(r.availability),availabilityDate:s(r.availability_date),groupId:s(r.group_id),listingHasVariations:Boolean(r.listing_has_variations),variantAttributes:r.variant_attributes??null,variants:r.variants??null,storeName:s(r.store_name)??'Adorama',sellerUrl:s(r.seller_url),sellerPrivacyPolicy:s(r.seller_privacy_policy),sellerTos:s(r.seller_tos),returnPolicy:s(r.return_policy),returnWindow:n(r.return_window),targetCountries:sa(r.target_countries),storeCountry:s(r.store_country),categoryUrls:sa(r.category_urls),starRating:n(r.star_rating),reviewCount:n(r.review_count),reviews:r.reviews??null,additionalImageUrls:sa(r.additional_image_urls).filter(x=>!x.includes('/undefined')),gtin:s(r.gtin),mpn:s(r.mpn),raw:input};
}
