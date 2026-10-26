export const TAX_FAMILIES=[
  "TAX_REGIME","TAX_JURISDICTION","TAX_JURISDICTION_ASSIGNMENT","STATE_RATE","LOCAL_RATE",
  "RATE_COMPONENT_RULE","RATE_CAP_THRESHOLD_RULE","PRODUCT_TAXABILITY","TAXABLE_BASE_RULE",
  "BUNDLED_TRANSACTION_RULE","ALLOCATION_RULE","TAX_HOLIDAY","SOURCING_RULE","SELLER_COLLECTION_RULE",
  "MARKETPLACE_RULE","SELLER_TAX_ELECTION","EXEMPTION_RULE","EXEMPTION_CERTIFICATE_REQUIREMENT",
  "TAX_CREDIT_RULE","ROUNDING_RULE","MANDATORY_TRANSACTION_FEE"
] as const;
export type TaxFamily=typeof TAX_FAMILIES[number];

export const TCDS_TAX_CATEGORIES=[
  "LAPTOPS","PHONES","NETWORKING","AUTOMOTIVE_TOOLS","GARDENING_TOOLS",
  "GAME_CONSOLES","MUSIC_EQUIPMENT","DRONES","CAMERAS","ELECTRONICS"
] as const;
export type TcdsTaxCategory=typeof TCDS_TAX_CATEGORIES[number];
export type PurchaseChannel='PHYSICAL_PICKUP'|'DELIVERY'|'SHIP_TO_STORE'|'MARKETPLACE';

export interface QuoteLine{
  lineId:string; sku:string; quantity:number; unitPriceCents:number;
  tcdsCategoryCode:TcdsTaxCategory|string;
  /** Advisory only; governed mapping is authoritative and mismatches are rejected. */
  taxProductClass?:string; taxProductSubclass?:string;
  attributes?:Record<string,unknown>; bundleId?:string;
}
export interface QuoteAdjustment{kind:'CHARGE'|'DISCOUNT'|'PRIOR_TAX';componentType:string;amountCents:number;lineId?:string}
export interface QuoteInput{
  externalCorrelationId?:string; transactionDate:string; evaluationAsOf:string; purchaseChannel:PurchaseChannel; stateCode:string;
  taxAddressId?:string; zip9?:string; zip5?:string; zsl2LocationId?:string; latitude?:number; longitude?:number;
  sellerContext:Record<string,unknown>; buyerTaxProfile:Record<string,unknown>; lines:QuoteLine[]; adjustments?:QuoteAdjustment[]
}
export interface Zsl6TaxAcquisitionCostAuthority{
  contractVersion:'zsl5-zsl6-tax-cost-v1'; transactionId:string; buildRunId:string; publicationId:string;
  evaluationAsOf:string; stateCode:string; taxableBaseCents:string; checkoutTaxEstimateCents:string|null;
  estimatedLegalTaxBurdenCents:string; potentialUseTaxCents:string; mandatoryGovernmentFeesCents:string;
  totalGovernmentAcquisitionCostCents:string; evidenceSha256:string;
}
