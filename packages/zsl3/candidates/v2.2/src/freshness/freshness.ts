export type FreshnessStatus='CURRENT'|'AGING'|'STALE'|'EXPIRED'|'UNKNOWN';
const order:Record<FreshnessStatus,number>={CURRENT:0,AGING:1,STALE:2,EXPIRED:3,UNKNOWN:4};
export function freshness(role:string,vintage:string,policy:any,asOf=new Date()){
 const y=Number(String(vintage).slice(0,4));if(!Number.isFinite(y))return{ageDays:null,status:'UNKNOWN' as FreshnessStatus};
 const releaseDate=new Date(Date.UTC(y+1,0,1));const ageDays=Math.max(0,Math.floor((asOf.getTime()-releaseDate.getTime())/86400000));
 const base=role.startsWith('ACS')?'ACS':role.startsWith('BEA_RPP')?'BEA_RPP':role.startsWith('CBP')?'CBP':role.startsWith('ZBP')?'ZBP':role;
 const t=policy.thresholdDays[base];if(!t)return{ageDays,status:'UNKNOWN' as FreshnessStatus};
 return{ageDays,status:(ageDays<=t.current?'CURRENT':ageDays<=t.aging?'AGING':ageDays<=t.stale?'STALE':'EXPIRED') as FreshnessStatus};
}
export function aggregateFreshness(inputs:{role:string;vintage:string}[],policy:any,asOf=new Date()){
 const details=inputs.map(i=>({...i,...freshness(i.role,i.vintage,policy,asOf)}));
 if(!details.length)return{ageDays:null,status:'UNKNOWN' as FreshnessStatus,inputs:details,rule:'WORST_MANDATORY_INPUT'};
 let worst=details[0]!;
 for(const d of details)if(order[d.status as FreshnessStatus]>order[worst.status as FreshnessStatus])worst=d;
 return{ageDays:worst.ageDays,status:worst.status as FreshnessStatus,inputs:details,rule:'WORST_MANDATORY_INPUT'};
}
