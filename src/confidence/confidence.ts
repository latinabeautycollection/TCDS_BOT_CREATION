export interface ConfidenceInputs{
 authority:number;freshness:string;coverage:number;missingness:string;sampleSize:number;inherited:boolean;
 suppression?:boolean;inputConfidence?:number;conflictPenalty?:number
}
export function confidence(args:ConfidenceInputs,p:any){
 const pen=p.penalties??{};const fw=args.freshness==='CURRENT'?1:args.freshness==='AGING'?.8:args.freshness==='STALE'?.5:args.freshness==='EXPIRED'?.2:.1;
 const mw=args.missingness==='PRESENT'?1:args.missingness==='DERIVED_FROM_PARENT'?.7:0;
 let score=(Math.max(0,Math.min(1,args.authority))*p.weights.authority)
 +(Math.max(0,Math.min(1,args.coverage))*p.weights.coverage)
 +(Math.min(1,Math.max(0,args.sampleSize)/20)*p.weights.sampleSize)
 +(fw*p.weights.freshness)+(mw*p.weights.missingness)+((args.inherited?0.5:1)*p.weights.inheritance);
 if(args.inputConfidence!=null)score*=Math.max(0,Math.min(1,args.inputConfidence));
 score-=args.missingness==='SUPPRESSED'?(pen.SUPPRESSED??0):args.missingness==='MISSING'?(pen.MISSING??0):args.missingness==='UNAVAILABLE'?(pen.UNAVAILABLE??0):args.missingness==='INVALID_SOURCE_VALUE'?(pen.UNAVAILABLE??0):args.inherited?(pen.DERIVED_FROM_PARENT??0):0;
 score-=args.conflictPenalty??0;score=Math.max(0,Math.min(1,score));
 const labels=p.labels??{};let label='INSUFFICIENT';
 for(const k of ['HIGH','MEDIUM','LOW','INSUFFICIENT']){const r=labels[k];if(Array.isArray(r)&&score>=r[0]&&score<=r[1]){label=k;break}}
 return{score,label,inputs:args,policyVersion:p.version};
}
