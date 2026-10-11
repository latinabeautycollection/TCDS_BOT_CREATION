export type CertifiedRawRecord={
  source_key:string;release_id:string;release_key:string;ingest_run_id:string;artifact_id:string;
  ordinal:string;natural_key:string;record_id:string;record:Record<string,unknown>;record_sha256:string
};

export type CanonicalLocationInput={
  locationType:'state'|'county'|'place'|'zcta'|'postal_code'|'cbsa';
  canonicalKey:string;
  displayName:string|null;
  authorityStatus:'AUTHORITATIVE'|'PROVISIONAL'|'PENDING_EXTERNAL_AUTHORITY';
  identityDocument:Record<string,unknown>;
  revisionDocument:Record<string,unknown>;
  latitude?:number;
  longitude?:number;
  sourceKey:string;releaseId:string;ingestRunId:string;recordId:string;recordSha256:string
};

export type ExactRatios={res:string|null;bus:string|null;oth:string|null;tot:string|null};
export type RelationshipInput={
  parentKey:string;childKey:string;
  relationshipType:'POSTAL_TO_COUNTY'|'POSTAL_TO_CBSA';
  authority:string;
  ratios:ExactRatios;
  sourceKey:string;releaseId:string;ingestRunId:string;recordId:string;recordSha256:string
};
