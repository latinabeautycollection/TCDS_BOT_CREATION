export type LocationType =
  | 'national' | 'region' | 'state' | 'metro' | 'postal_code' | 'store';

export type LocationStatus =
  | 'draft' | 'verified' | 'approved' | 'suspended' | 'retired';

export type AdapterStatus =
  | 'uncertified' | 'test_only' | 'partially_dynamic'
  | 'certified_dynamic_search' | 'suspended' | 'retired';

export type AdapterType =
  | 'search' | 'product_detail' | 'store_inventory'
  | 'category_discovery' | 'hybrid';

export interface AdapterCapabilities {
  keywordSearch: boolean;
  productUrl: boolean;
  categorySearch: boolean;
  storeId: boolean;
  postalCode: boolean;
  region: boolean;
  resultLimit: boolean;
  collectionMethods: string[];
  sourceTypes: string[];
}
