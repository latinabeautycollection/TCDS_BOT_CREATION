export type GeographyScope='STATE'|'COUNTY'|'PLACE'|'ZCTA'|'POSTAL_CODE'|'MSA';
export type EvidenceClass='SOURCE_FACT'|'DERIVED_FEATURE';
export type Missingness='PRESENT'|'MISSING'|'UNAVAILABLE'|'SUPPRESSED'|'NOT_APPLICABLE'|'CONFLICTED'|'DERIVED_FROM_PARENT'|'INVALID_SOURCE_VALUE';
export interface SourceSpec{sourceKey:string;dataset:string;geographies:GeographyScope[];required:boolean;requiresAuthoritativeMetroMapping?:boolean}
export interface SourcePolicy{
  version:string;engineVersion:string;requiredSources:SourceSpec[];evidenceClasses:EvidenceClass[];
  forbiddenEvidenceClasses:string[];allowFuzzyGeographyMatch:boolean;requireExactUpstreamPackages:boolean;
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
