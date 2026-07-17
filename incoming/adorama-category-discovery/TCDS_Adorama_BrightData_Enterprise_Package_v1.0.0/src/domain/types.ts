export type JobState = "queued"|"triggering"|"running"|"downloading"|"ingesting"|"completed"|"retry_wait"|"dead_lettered"|"cancelled";
export interface TriggerInput { url:string }
export interface BrightDataProgress { status?:string; snapshot_id?:string; id?:string; error?:string; error_message?:string; dataset_size?:number }
export interface AdoramaRawRecord { [key:string]:unknown }
export interface NormalizedProduct {
  sourceUrl:string; itemId:string; variantId:string; title:string; description:string|null;
  productCategory:string|null; categoryTree:unknown[]; brand:string|null; imageUrl:string|null;
  price:number|null; salePrice:number|null; currency:string; availability:string|null;
  availabilityDate:string|null; groupId:string|null; listingHasVariations:boolean;
  variantAttributes:unknown; variants:unknown; storeName:string; sellerUrl:string|null;
  sellerPrivacyPolicy:string|null; sellerTos:string|null; returnPolicy:string|null;
  returnWindow:number|null; targetCountries:string[]; storeCountry:string|null;
  categoryUrls:string[]; starRating:number|null; reviewCount:number|null; reviews:unknown;
  additionalImageUrls:string[]; gtin:string|null; mpn:string|null; raw:AdoramaRawRecord;
}
