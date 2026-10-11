export type IngestState="DISCOVERED"|"DOWNLOADED"|"VALIDATED"|"LOADED"|"RECONCILED"|"FAILED"|"QUARANTINED"|"SUPERSEDED";
export type CertificationStatus="PENDING"|"CERTIFIED"|"FAILED"|"REVOKED"|"SUPERSEDED";
export interface SourceRelease {sourceKey:string;releaseKey:string;releaseLabel:string;sourceYear?:number;sourceQuarter?:number;discoveredAt:string;metadata:Record<string,unknown>}
export interface RetrievedArtifact {sourceKey:string;releaseKey:string;fileName:string;localPath:string;sourceUrl:string;byteCount:number;sha256:string;retrievedAt:string;contentType?:string;etag?:string;lastModified?:string}
export interface RawSourceRecord {naturalKey:string;record:Record<string,unknown>}
export interface ValidationIssue {code:string;message:string;fatal:boolean;field?:string}
export interface ArtifactValidation {valid:boolean;issues:ValidationIssue[];schemaSha256:string;evidence?:Record<string,unknown>}
export interface RecordValidation {valid:boolean;issues:ValidationIssue[]}
export interface ReconciliationResult {ok:boolean;parsedCount:number;loadedMembershipCount:number;distinctRecordCount:number;issues:ValidationIssue[]}
export interface IngestContext {ingestRunId:string;releaseId:string;artifactId:string;sourceKey:string;releaseKey:string}
export interface ZslSourceAdapter {readonly sourceKey:string;readonly adapterVersion:string;discoverRelease():Promise<SourceRelease>;retrieve(release:SourceRelease):Promise<RetrievedArtifact>;validateArtifact(artifact:RetrievedArtifact):Promise<ArtifactValidation>;parse(artifact:RetrievedArtifact):AsyncIterable<RawSourceRecord>;validateRecord(record:RawSourceRecord):RecordValidation;reconcile(context:IngestContext):Promise<ReconciliationResult>}
