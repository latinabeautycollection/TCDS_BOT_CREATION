import type pg from 'pg';
import {sha256Json} from '../core/hash.js';
import {deterministicReplay} from './replay.service.js';

export type CertificationPolicy={requiredCertifiedSources:string[];relationshipRatioTolerance?:number};

async function saveCheck(c:pg.PoolClient,runId:string,name:string,passed:boolean,measured:Record<string,unknown>){
 const hash=sha256Json({name,passed,measured});
 await c.query(`insert into zsl.zsl2_runtime_checks(normalization_run_id,check_name,passed,measured_value,evidence_sha256)
 values($1,$2,$3,$4::jsonb,$5) on conflict(normalization_run_id,check_name) do nothing`,[runId,name,passed,JSON.stringify(measured),hash]);
}

export async function buildCertificationEvidence(c:pg.PoolClient,runId:string,policy:CertificationPolicy,expectedZsl1PackageSha?:string){
 const one=async(s:string,p:any[]=[runId])=>Number((await c.query(s,p)).rows[0].n);
 const bindingRows=(await c.query(`select source_key,release_id::text,ingest_run_id::text,certification_run_id::text from zsl.zsl2_source_bindings where normalization_run_id=$1 order by source_key`,[runId])).rows;
 const actualSources=bindingRows.map((x:any)=>String(x.source_key));
 const expected=[...policy.requiredCertifiedSources].sort(),actual=[...actualSources].sort();
 const exactSourceSet=JSON.stringify(expected)===JSON.stringify(actual);

 const boundRecords=await one(`select count(*) n from zsl.certified_release_records cr join zsl.zsl2_source_bindings b on b.normalization_run_id=$1 and b.source_key=cr.source_key and b.release_id=cr.release_id and b.ingest_run_id=cr.ingest_run_id`);
 const lineage=await one(`select count(*) n from zsl.zsl2_record_lineage where normalization_run_id=$1`);
 const outside=await one(`select count(*) n from zsl.zsl2_record_lineage l where l.normalization_run_id=$1 and not exists(select 1 from zsl.zsl2_source_bindings b where b.normalization_run_id=l.normalization_run_id and b.source_key=l.source_key and b.release_id=l.release_id and b.ingest_run_id=l.ingest_run_id)`);
 const fatal=await one(`select count(*) n from zsl.zsl2_conflicts where normalization_run_id=$1 and severity='FATAL' and not resolved`);
 const orphan=await one(`select count(*) n from zsl.zsl2_relationship_run_memberships m join zsl.location_relationships r on r.relationship_id=m.relationship_id left join zsl.locations p on p.location_id=r.parent_location_id left join zsl.locations ch on ch.location_id=r.child_location_id where m.normalization_run_id=$1 and (p.location_id is null or ch.location_id is null)`);
 const noHash=await one(`select count(*) n from zsl.zsl2_location_run_memberships m join zsl.locations l on l.location_id=m.location_id where m.normalization_run_id=$1 and l.identity_sha256!~'^[0-9a-f]{64}$'`);
 const locLineageMissing=await one(`select count(*) n from zsl.zsl2_record_lineage l where l.normalization_run_id=$1 and l.canonical_location_id is not null and not exists(select 1 from zsl.zsl2_location_run_memberships m where m.normalization_run_id=l.normalization_run_id and m.location_id=l.canonical_location_id and m.source_record_sha256=l.raw_record_sha256)`);
 const relLineageMissing=await one(`select count(*) n from zsl.zsl2_record_lineage l where l.normalization_run_id=$1 and l.canonical_relationship_id is not null and not exists(select 1 from zsl.zsl2_relationship_run_memberships m where m.normalization_run_id=l.normalization_run_id and m.relationship_id=l.canonical_relationship_id and m.source_record_sha256=l.raw_record_sha256)`);
 const coordBad=await one(`select count(*) n from zsl.zsl2_location_revisions r where r.normalization_run_id=$1 and ((r.latitude is null)<>(r.longitude is null) or r.latitude not between -90 and 90 or r.longitude not between -180 and 180)`);
 const gazNoPoint=await one(`select count(*) n from zsl.zsl2_location_revisions r where r.normalization_run_id=$1 and r.source_key like 'CENSUS_GAZETTEER_%' and r.point is null`);

 const tol=policy.relationshipRatioTolerance??0.000001;
 const ratioBad=await one(`with normal as (
   select r.relationship_type,r.source_release_id,r.child_location_id,
          r.res_ratio,r.bus_ratio,r.oth_ratio,r.tot_ratio
   from zsl.zsl2_relationship_run_memberships m join zsl.location_relationships r on r.relationship_id=m.relationship_id
   where m.normalization_run_id=$1 and r.relationship_type in('POSTAL_TO_COUNTY','POSTAL_TO_CBSA')
 ), outside as (
   select 'POSTAL_TO_CBSA'::text relationship_type,f.source_release_id,f.postal_location_id child_location_id,
          f.res_ratio,f.bus_ratio,f.oth_ratio,f.tot_ratio
   from zsl.zsl2_postal_outside_cbsa_facts f where f.normalization_run_id=$1
 ), g as (
   select relationship_type,source_release_id,child_location_id,
          sum(res_ratio) filter(where res_ratio is not null) res_sum,
          sum(bus_ratio) filter(where bus_ratio is not null) bus_sum,
          sum(oth_ratio) filter(where oth_ratio is not null) oth_sum,
          sum(tot_ratio) filter(where tot_ratio is not null) tot_sum
   from (select * from normal union all select * from outside) u group by 1,2,3)
 select count(*) n from g where
   (res_sum is not null and abs(res_sum-1)>$2) or (bus_sum is not null and abs(bus_sum-1)>$2) or
   (oth_sum is not null and abs(oth_sum-1)>$2) or (tot_sum is not null and abs(tot_sum-1)>$2)`,[runId,tol]);

 const derivedHierarchyMissing=await one(`with locs as (
   select distinct m.location_id,l.location_type,l.canonical_key from zsl.zsl2_location_run_memberships m join zsl.locations l on l.location_id=m.location_id where m.normalization_run_id=$1
 )
 select count(*) n from locs x where
   (x.location_type='state' and not exists(select 1 from zsl.zsl2_relationship_run_memberships rm join zsl.location_relationships r on r.relationship_id=rm.relationship_id join zsl.locations p on p.location_id=r.parent_location_id where rm.normalization_run_id=$1 and r.child_location_id=x.location_id and r.relationship_type='CONTAINS' and p.canonical_key='US:NATIONAL'))
   or
   (x.location_type in('county','place') and not exists(select 1 from zsl.zsl2_relationship_run_memberships rm join zsl.location_relationships r on r.relationship_id=rm.relationship_id join zsl.locations p on p.location_id=r.parent_location_id where rm.normalization_run_id=$1 and r.child_location_id=x.location_id and r.relationship_type='STATE_OF' and p.location_type='state'))`);


 const upstreamPackageRows=(await c.query(`select distinct ir.package_sha256 from zsl.zsl2_source_bindings b join zsl.ingest_runs ir on ir.ingest_run_id=b.ingest_run_id where b.normalization_run_id=$1`,[runId])).rows.map((x:any)=>String(x.package_sha256??''));
 const upstreamPackageMatch=Boolean(expectedZsl1PackageSha)&&upstreamPackageRows.length===1&&upstreamPackageRows[0]===expectedZsl1PackageSha;

 const vintages=(await c.query(`select b.source_key,sr.source_year,sr.source_quarter from zsl.zsl2_source_bindings b join zsl.source_releases sr on sr.release_id=b.release_id where b.normalization_run_id=$1 order by b.source_key`,[runId])).rows;
 const censusRows=vintages.filter((x:any)=>String(x.source_key).startsWith('CENSUS_GAZETTEER_'));
 const censusYears=censusRows.map((x:any)=>String(x.source_year??''));
 const hudRows=vintages.filter((x:any)=>String(x.source_key).startsWith('HUD_USPS_'));
 const hudVintages=hudRows.map((x:any)=>({year:String(x.source_year??''),quarter:Number(x.source_quarter)}));
 const sourceVintageCoherence=censusRows.length===4&&censusYears.every((y:string)=>/^\d{4}$/.test(y))&&new Set(censusYears).size===1&&hudRows.length===2&&hudVintages.every((v:any)=>/^\d{4}$/.test(v.year)&&Number.isInteger(v.quarter)&&v.quarter>=1&&v.quarter<=4)&&new Set(hudVintages.map((v:any)=>`${v.year}-Q${v.quarter}`)).size===1;

 const replay=await deterministicReplay(c,runId);
 const checks={
   exact_source_set:exactSourceSet,
   bound_records_only:outside===0,
   zero_fatal_conflicts:fatal===0,
   zero_orphans:orphan===0,
   identity_hash_coverage:noHash===0,
   lineage_coverage:boundRecords===lineage,
   deterministic_replay:replay.pass,
   hud_ratio_reconciliation:ratioBad===0,
   coordinate_sanity:coordBad===0&&gazNoPoint===0,
   run_membership_complete:locLineageMissing===0&&relLineageMissing===0,
   upstream_package_match:upstreamPackageMatch,
   source_vintage_coherence:sourceVintageCoherence,
   derived_hierarchy_coverage:derivedHierarchyMissing===0
 };
 const measured={expectedSources:expected,actualSources:actual,boundRecords,lineage,outside,fatal,orphan,noHash,locLineageMissing,relLineageMissing,coordBad,gazNoPoint,ratioBad,upstreamPackageRows,expectedZsl1PackageSha,vintages,sourceVintageCoherence,derivedHierarchyMissing,replay};
 for(const [name,passed] of Object.entries(checks))await saveCheck(c,runId,name,passed,{...measured,check:name});
 return {checks,counts:measured,replay};
}
export function sealEvidence(e:unknown){return sha256Json(e);}
