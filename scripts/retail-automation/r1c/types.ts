export type R1CCompileMode =
  | 'keyword'
  | 'category'
  | 'product_url'
  | 'store_inventory';

export type R1CTransport =
  | 'env'
  | 'argv'
  | 'json'
  | 'query'
  | 'hybrid';

export interface R1CScraperAuthority {
  adapter_id:string;
  scraper_asset_id:string;
  implementation_authority_type:'file'|'package_tree';
  implementation_root:string;
  package_tree_sha256:string;
  entrypoint_sha256:string|null;
  verification_evidence_sha256:string;
  scraper_contract_id:string;
  scraper_contract_version:string;
  scraper_contract_sha256:string;
  interface_evidence_sha256:string;
  contract_required_fields:string[];
  contract_status:'certified_for_r1';
  execution_ready:true;
}

export interface EffectiveSearchRoute {
  route_id:string;
  route_authority_hash:string;
  target_id:string;
  r1a_revision_id:string;
  r1a_revision_hash:string;
  platform_id:string;
  platform_code:string;
  adapter_id:string;
  adapter_code:string;
  adapter_version:string;
  implementation_ref:string;
  implementation_sha256:string;
  input_contract_json:{
    transport:R1CTransport;
    compile_modes:R1CCompileMode[];
    field_map:Record<string,string>;
    required_fields:string[];
  };
  supports_keyword_search:boolean;
  supports_product_url:boolean;
  supports_category_search:boolean;
  supports_store_id:boolean;
  supports_postal_code:boolean;
  supports_region:boolean;
  supports_result_limit:boolean;
  location_type:string|null;
  postal_code:string|null;
  retailer_store_id:string|null;
}

export interface CompiledSearchJob {
  id:string;
  compilation_key:string;
  route_id:string;
  route_authority_hash:string;
  compiler_authority_sha256:string;
  normalized_job_json:Record<string,unknown>;
  adapter_payload_json:Record<string,unknown>;
  compilation_evidence_json:{
    scraper_authority:R1CScraperAuthority;
    [key:string]:unknown;
  };
  normalized_job_sha256:string;
  adapter_payload_sha256:string;
  compilation_evidence_sha256:string;
}
