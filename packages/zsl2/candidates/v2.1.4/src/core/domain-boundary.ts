export const ZSL2_OWNED_CONCEPTS = Object.freeze([
  'canonical_geography_identity','state','county','place','zcta','postal_observation','cbsa_code',
  'geography_relationship','geography_lineage','geography_conflict','postgis_geography','spatial_query'
] as const);

export const ZSL2_FORBIDDEN_OWNERSHIP = Object.freeze([
  'retailer_identity','retailer_store_master','retailer_account','search_authorization','scraper_execution',
  'r1c_compilation','r1d_scheduling','economic_intelligence','freight_authority','tax_authority',
  'retail_offer_authority','arbitrage_decision','capital_allocation','purchase_qualification','checkout',
  'order_lifecycle','warehouse_inventory','shipping_tracking','ebay_lifecycle'
] as const);

export function assertZsl2Capability(capability: string): void {
  if ((ZSL2_FORBIDDEN_OWNERSHIP as readonly string[]).includes(capability)) {
    throw new Error(`ZSL2_DOMAIN_BOUNDARY_VIOLATION:${capability}`);
  }
}
