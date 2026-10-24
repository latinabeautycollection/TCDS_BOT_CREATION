export type GeographyScope='STATE'|'COUNTY'|'PLACE'|'ZCTA'|'POSTAL_CODE'|'MSA';
export type EvidenceClass='SOURCE_FACT'|'DERIVED_FEATURE';
export type Missingness='PRESENT'|'MISSING'|'UNAVAILABLE'|'SUPPRESSED'|'NOT_APPLICABLE'|'CONFLICTED'|'DERIVED_FROM_PARENT'|'INVALID_SOURCE_VALUE';
export interface SourceSpec{sourceKey:string;dataset:string;geographies:GeographyScope[];required:boolean;requiresAuthoritativeMetroMapping?:boolean}
export interface GeographyCrosswalk{sourceKey:string;sourceVintage:string;geography:GeographyScope;sourceGEOID:string;targetCanonicalKey:string;authorityCode:string}
export interface GeographyExclusion{sourceKey:string;sourceVintage:string;sourceReleaseId:string;geography:GeographyScope;sourceGEOID:string;authorityCode:string;reasonCode:'NO_CURRENT_ANSI_SUCCESSOR'}
export interface GeographyExclusionRule{sourceKey:string;sourceVintage:string;sourceReleaseId:string;geography:GeographyScope;field:'county'|'zip';value:string;expectedCount:number;reasonCode:string;sourceGEOID?:never}
export interface SourcePolicy{
  version:string;engineVersion:string;requiredSources:SourceSpec[];evidenceClasses:EvidenceClass[];
  forbiddenEvidenceClasses:string[];allowFuzzyGeographyMatch:boolean;requireExactUpstreamPackages:boolean;
  geographyCrosswalks:GeographyCrosswalk[];
  geographyExclusions:GeographyExclusion[];
  geographyExclusionRules:GeographyExclusionRule[];
  geographyExclusionEvidence?:{
    cbpCounty2023?:{releaseId:string;countyValue:string;sourceRecordCount:number;distinctStates:number;disposition:string};
    zbpHud2025Q4:{releaseId:string;hudSnapshot:string;csvSha256:string;distinctZipCount:number;sourceRecordCount:number;disposition:string};
  };
  geographyEvidence:{source2024Url:string;source2024Sha256:string;target2026Url:string;target2026Sha256:string};
  requireCurrentUpstreamCertifications:boolean;vintageCoherence:Record<string,string>;
  coverageExpectations:Record<string,{requiredSources:string[];optionalSources:string[]}>;
  locationCoverageMinimumPct:Record<string,number>;
}
export interface DerivedDefinition{
  featureCode:string;formulaVersion:string;formulaType:'ARITHMETIC'|'PERCENT_RANK';formula:string;
  requires:string[];unit:string;freshnessAggregation?:'WORST_MANDATORY_INPUT'
}
export interface FeaturePolicy{version:string;minimumPercentileCohortSize:number;acsVariableBindings:any[];derivedDefinitions:DerivedDefinition[]}
export interface PolicyBundle{
  source:SourcePolicy;feature:FeaturePolicy;confidence:any;freshness:any;naics:any;upstream:any;certification:any;
  hashes:Record<string,string>
}
