export type TaxRecordType =
  'TAX_REGIME'
  | 'TAX_JURISDICTION'
  | 'TAX_JURISDICTION_ASSIGNMENT'
  | 'STATE_RATE'
  | 'LOCAL_RATE'
  | 'RATE_COMPONENT_RULE'
  | 'RATE_CAP_THRESHOLD_RULE'
  | 'PRODUCT_TAXABILITY'
  | 'TAXABLE_BASE_RULE'
  | 'BUNDLED_TRANSACTION_RULE'
  | 'ALLOCATION_RULE'
  | 'TAX_HOLIDAY'
  | 'SOURCING_RULE'
  | 'SELLER_COLLECTION_RULE'
  | 'MARKETPLACE_RULE'
  | 'SELLER_TAX_ELECTION'
  | 'EXEMPTION_RULE'
  | 'EXEMPTION_CERTIFICATE_REQUIREMENT'
  | 'TAX_CREDIT_RULE'
  | 'ROUNDING_RULE'
  | 'MANDATORY_TRANSACTION_FEE';

export interface EvidenceContext {
  sourceKey: string;
  releaseId: string;
  artifactSha256: string;
  authorityRank: number;
  retrievedAt: string;
  parserVersion: string;
  normalizationVersion: string;
}

export interface CanonicalTaxRecord {
  record_type: TaxRecordType;
  state_code: string;
  natural_key: string;
  source_key: string;
  source_release_id: string;
  source_artifact_sha256: string;
  authority_rank: number;
  published_at: string | null;
  effective_from: string | null;
  effective_to: string | null;
  retrieved_at: string;
  parser_version: string;
  normalization_version: string;
  legal_citation: string | null;
  payload: Record<string, unknown>;
}

export interface ParserAdapter {
  adapterKey: string;
  recordTypes: TaxRecordType[];
  canParse(input: { sourceKey: string; filename: string; contentType?: string | null }): boolean;
  parse(bytes: Buffer, context: EvidenceContext, filename: string): Promise<CanonicalTaxRecord[]>;
}
