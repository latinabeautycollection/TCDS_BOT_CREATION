import { readFile } from "node:fs/promises";
import { sha256Canonical } from "./hash.js";
export interface SourcePolicy {
  sourceKey:string; enabled:boolean; allowedHosts:string[]; maxArtifactBytes:number; maxExpandedBytes:number;
  maxMembers:number; maxMemberBytes:number; maxCompressionRatio:number; retry:{attempts:number;baseDelayMs:number;maxDelayMs:number};
  expectedContentTypes?:string[]; rowCount?:{min:number;max:number}; requiredFields?:string[]; allowExtraFields?:boolean;
  requireContentType?:boolean; requireArtifactMagic?:boolean; maxNaturalKeyBytes?:number; maxRecordBytes?:number; maxNullRequiredRatePercent?:number;
}
export interface PolicyDocument {version:string;sources:Record<string,SourcePolicy>}
export async function loadPolicy(path="config/source-policy.json"):Promise<{doc:PolicyDocument;sha256:string}>{const text=await readFile(path,"utf8");const doc=JSON.parse(text) as PolicyDocument;return {doc,sha256:sha256Canonical(doc)}}
