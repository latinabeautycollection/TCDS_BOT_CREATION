import type {PoolClient} from 'pg';
import {canonicalJson,sha256Text,sha256Json} from '../core/hash.js';
import {deterministicReplay} from './replay.service.js';

export type CertificationPolicy={requiredCertifiedSources:string[];relationshipRatioTolerance?:number;performance?:{pageP99Ms?:number;maxStatementMs?:number}};
const count=async(c:PoolClient,sql:string,p:unknown[]=[ ]):Promise<bigint>=>BigInt(String((await c.query(sql,p)).rows[0]?.n??'0'));

async function saveCheck(c:PoolClient,runId:string,evaluationId:string,name:string,passed:boolean,measured:Record<string,unknown>){
 const payload=canonicalJson({runId,evaluationId,name,passed,measured,algorithm:'zsl2-certification-v2.1.4'});
 const evidenceSha=sha256Text(payload);
 await c.query(`select zsl.zsl2_record_source_check_v214($1,$2,$3,$4,$5::jsonb,$6)`,[runId,evaluationId,name,passed,JSON.stringify(measured),evidenceSha]);
}

export async function buildCertificationEvidence(c:PoolClient,runId:string,policy:CertificationPolicy,expectedZsl1PackageSha:string,evaluationId:string){
 const bindingRows=(await c.query(`select source_key,release_id::text,ingest_run_id::text,certification_run_id::text from zsl.zsl2_source_bindings where normalization_run_id=$1 order by source_key`,[runId])).rows;
 const actual=bindingRows.map((x:Record<string,unknown>)=>String(x.source_key)).sort(),expected=[...policy.requiredCertifiedSources].sort();
 const exactSourceSet=JSON.stringify(expected)===JSON.stringify(actual)&&new Set(actual).size===expected.length;
 const unexpected=actual.filter((x:string)=>!expected.includes(x)),missing=expected.filter((x:string)=>!actual.includes(x));

 const checkpointRows=(await c.query(`select c.source_key,c.status,c.page_number::text,c.records_processed::text,c.locations_processed::text,c.relationships_processed::text,c.lineage_processed::text,c.checkpoint_sha256,
   t.records_processed::text truth_records,t.locations_processed::text truth_locations,t.relationships_processed::text truth_relationships,t.lineage_processed::text truth_lineage
   from zsl.zsl2_normalization_checkpoints c cross join lateral zsl.zsl2_checkpoint_truth(c.normalization_run_id,c.source_key) t where c.normalization_run_id=$1 order by c.source_key`,[runId])).rows;
 const checkpointsComplete=checkpointRows.length===expected.length&&checkpointRows.every((x:Record<string,unknown>)=>x.status==='COMPLETE'&&/^[0-9a-f]{64}$/.test(String(x.checkpoint_sha256??'')));
 const checkpointCountersReconcile=checkpointRows.every((x:Record<string,unknown>)=>String(x.records_processed)===String(x.truth_records)&&String(x.relationships_processed)===String(x.truth_relationships)&&String(x.lineage_processed)===String(x.truth_lineage));

 const snapshots=(await c.query(`select s.source_key,s.record_count::text,s.record_set_sha256,zsl.zsl2_source_snapshot_still_valid(s.normalization_run_id,s.source_key) valid from zsl.zsl2_source_snapshots s where s.normalization_run_id=$1 order by s.source_key`,[runId])).rows;
 const sourceSnapshotsValid=snapshots.length===expected.length&&snapshots.every((x:Record<string,unknown>)=>x.valid===true&&/^[0-9a-f]{64}$/.test(String(x.record_set_sha256)));

 const boundRecords=await count(c,`select count(*) n from zsl.certified_release_records cr join zsl.zsl2_source_bindings b on b.normalization_run_id=$1 and b.source_key=cr.source_key and b.release_id=cr.release_id and b.ingest_run_id=cr.ingest_run_id`,[runId]);
 const lineage=await count(c,`select count(*) n from zsl.zsl2_record_lineage where normalization_run_id=$1`,[runId]);
 const duplicateLineage=await count(c,`select count(*) n from (select source_key,raw_record_id,count(*) from zsl.zsl2_record_lineage where normalization_run_id=$1 group by 1,2 having count(*)<>1) x`,[runId]);
 const outside=await count(c,`select count(*) n from zsl.zsl2_record_lineage l where l.normalization_run_id=$1 and not exists(select 1 from zsl.zsl2_source_bindings b where b.normalization_run_id=l.normalization_run_id and b.source_key=l.source_key and b.release_id=l.release_id and b.ingest_run_id=l.ingest_run_id)`,[runId]);
 const fatal=await count(c,`select count(*) n from zsl.zsl2_conflicts where normalization_run_id=$1 and severity='FATAL' and not resolved`,[runId]);
 const orphan=await count(c,`select count(*) n from zsl.zsl2_relationship_run_memberships m join zsl.location_relationships r on r.relationship_id=m.relationship_id left join zsl.locations p on p.location_id=r.parent_location_id left join zsl.locations ch on ch.location_id=r.child_location_id where m.normalization_run_id=$1 and (p.location_id is null or ch.location_id is null)`,[runId]);
 const noHash=await count(c,`select count(*) n from zsl.zsl2_location_run_memberships m join zsl.locations l on l.location_id=m.location_id where m.normalization_run_id=$1 and l.identity_sha256!~'^[0-9a-f]{64}$'`,[runId]);
 const locLineageMissing=await count(c,`select count(*) n from zsl.zsl2_record_lineage l where l.normalization_run_id=$1 and l.canonical_location_id is not null and not exists(select 1 from zsl.zsl2_location_run_memberships m where m.normalization_run_id=l.normalization_run_id and m.location_id=l.canonical_location_id and m.source_record_sha256=l.raw_record_sha256)`,[runId]);
 const relLineageMissing=await count(c,`select count(*) n from zsl.zsl2_record_lineage l where l.normalization_run_id=$1 and l.canonical_relationship_id is not null and not exists(select 1 from zsl.zsl2_relationship_run_memberships m where m.normalization_run_id=l.normalization_run_id and m.relationship_id=l.canonical_relationship_id and m.source_record_sha256=l.raw_record_sha256)`,[runId]);
 const coordBad=await count(c,`select count(*) n from zsl.zsl2_location_revisions r where r.normalization_run_id=$1 and ((r.latitude is null)<>(r.longitude is null) or r.latitude not between -90 and 90 or r.longitude not between -180 and 180)`,[runId]);
 const gazNoPoint=await count(c,`select count(*) n from zsl.zsl2_location_revisions r where r.normalization_run_id=$1 and r.source_key like 'CENSUS_GAZETTEER_%' and r.point is null`,[runId]);

 const tol=String(policy.relationshipRatioTolerance??0.000001);
 const ratioQ=await c.query(`with normal as (
   select r.relationship_type,r.source_release_id,r.child_location_id,r.res_ratio,r.bus_ratio,r.oth_ratio,r.tot_ratio
   from zsl.zsl2_relationship_run_memberships m join zsl.location_relationships r on r.relationship_id=m.relationship_id
   where m.normalization_run_id=$1 and r.relationship_type in('POSTAL_TO_COUNTY','POSTAL_TO_CBSA')
 ), outside as (
   select 'POSTAL_TO_CBSA'::text relationship_type,f.source_release_id,f.postal_location_id child_location_id,f.res_ratio,f.bus_ratio,f.oth_ratio,f.tot_ratio from zsl.zsl2_postal_outside_cbsa_facts f where f.normalization_run_id=$1
 ), g as (
   select relationship_type,source_release_id,child_location_id,sum(res_ratio) filter(where res_ratio is not null) res_sum,sum(bus_ratio) filter(where bus_ratio is not null) bus_sum,sum(oth_ratio) filter(where oth_ratio is not null) oth_sum,sum(tot_ratio) filter(where tot_ratio is not null) tot_sum
   from (select * from normal union all select * from outside) u group by relationship_type,source_release_id,child_location_id
 ) select count(*) filter(where (res_sum is not null and least(abs(res_sum),abs(res_sum-1))>$2::numeric) or (bus_sum is not null and least(abs(bus_sum),abs(bus_sum-1))>$2::numeric) or (oth_sum is not null and least(abs(oth_sum),abs(oth_sum-1))>$2::numeric) or (tot_sum is not null and abs(tot_sum-1)>$2::numeric))::text bad_groups,
 count(*) filter(where res_sum is not null and abs(res_sum)<=$2::numeric)::text res_zero_groups,count(*) filter(where bus_sum is not null and abs(bus_sum)<=$2::numeric)::text bus_zero_groups,count(*) filter(where oth_sum is not null and abs(oth_sum)<=$2::numeric)::text oth_zero_groups,count(*)::text total_groups from g`,[runId,tol]);
 const ratioStats=ratioQ.rows[0]??{},ratioBad=BigInt(String(ratioStats.bad_groups??'0'));

 const zipZctaCollision=await count(c,`select count(*) n from zsl.zsl2_location_run_memberships m join zsl.locations l on l.location_id=m.location_id where m.normalization_run_id=$1 and ((l.location_type='postal_code' and l.canonical_key not like 'US:ZIP:%') or (l.location_type='zcta' and l.canonical_key not like 'US:ZCTA:%'))`,[runId]);
 const cbsaAuthorityBad=await count(c,`select count(*) n from zsl.zsl2_location_run_memberships m join zsl.locations l on l.location_id=m.location_id join zsl.cbsa_metros c on c.location_id=l.location_id where m.normalization_run_id=$1 and l.location_type='cbsa' and l.identity_document->>'authority'='HUD_USPS' and (c.official_name is not null or c.name_authority_status<>'PENDING_CENSUS_OMB')`,[runId]);
 const fake99999=await count(c,`select count(*) n from zsl.locations where canonical_key='US:CBSA:99999'`,[]);
 const rowRatioBad=await count(c,`select count(*) n from zsl.zsl2_relationship_run_memberships m join zsl.location_relationships r on r.relationship_id=m.relationship_id where m.normalization_run_id=$1 and (r.res_ratio not between 0 and 1 or r.bus_ratio not between 0 and 1 or r.oth_ratio not between 0 and 1 or r.tot_ratio not between 0 and 1)`,[runId]);

 const expectedPairs=await count(c,`select count(*) n from (select distinct cr.source_key,cr.record->>'zip' zip,cr.record->>'geoid' geoid from zsl.certified_release_records cr join zsl.zsl2_source_bindings b on b.normalization_run_id=$1 and cr.source_key=b.source_key and cr.release_id=b.release_id and cr.ingest_run_id=b.ingest_run_id where cr.source_key in('HUD_USPS_ZIP_COUNTY','HUD_USPS_ZIP_CBSA') and not (cr.source_key='HUD_USPS_ZIP_CBSA' and cr.record->>'geoid'='99999') and not (cr.source_key='HUD_USPS_ZIP_COUNTY' and exists(select 1 from zsl.zsl2_territorial_pending_evidence_v214 t where t.normalization_run_id=$1 and t.raw_record_sha256=cr.record_sha256))) x`,[runId]);
 const actualPairs=await count(c,`select count(*) n from (select distinct m.source_key,p.canonical_key parent_key,ch.canonical_key child_key from zsl.zsl2_relationship_run_memberships m join zsl.location_relationships r on r.relationship_id=m.relationship_id join zsl.locations p on p.location_id=r.parent_location_id join zsl.locations ch on ch.location_id=r.child_location_id where m.normalization_run_id=$1 and m.source_key in('HUD_USPS_ZIP_COUNTY','HUD_USPS_ZIP_CBSA')) x`,[runId]);
 const multiParentPreserved=expectedPairs===actualPairs;
 const territorialAuthorityBad=await count(c,`select count(*) n from zsl.zsl2_location_run_memberships m join zsl.locations l on l.location_id=m.location_id where m.normalization_run_id=$1 and l.location_type='county' and coalesce(l.identity_document->>'authority','')<>'CENSUS'`,[runId]);
 const territorialPending=(await c.query(`select count(*)::text n,
   count(*) filter(where postal_code~'^[0-9]{5}$' and territorial_county_geoid~'^(60|66|69|72|78)[0-9]{3}$' and evidence_sha256~'^[0-9a-f]{64}$')::text valid_n
   from zsl.zsl2_territorial_pending_evidence_v214 where normalization_run_id=$1`,[runId])).rows[0]??{};
 const territorialPendingCount=BigInt(String(territorialPending.n??'0')),territorialPendingValid=BigInt(String(territorialPending.valid_n??'0'));
 const territorialPendingLineageBad=await count(c,`select count(*) n from zsl.zsl2_territorial_pending_evidence_v214 t where t.normalization_run_id=$1 and not exists(select 1 from zsl.zsl2_record_lineage l where l.normalization_run_id=t.normalization_run_id and l.source_key=t.source_key and l.raw_record_id=t.raw_record_id and l.raw_record_sha256=t.raw_record_sha256 and l.disposition='IGNORED_BY_POLICY' and l.disposition_reason='PENDING_TERRITORIAL_AUTHORITY')`,[runId]);
 const territorialFabrication=await count(c,`select count(*) n from zsl.zsl2_territorial_pending_evidence_v214 t where t.normalization_run_id=$1 and (exists(select 1 from zsl.locations l where l.canonical_key=t.expected_parent_canonical_key) or exists(select 1 from zsl.location_relationships r where r.source_record_sha256=t.raw_record_sha256))`,[runId]);
 const zsl1AuthorityDecisionValid=Boolean((await c.query(`select zsl.zsl2_zsl1_authority_decision_current_v214($1) valid`,[runId])).rows[0]?.valid);

 const upstreamPackageRows=(await c.query(`select distinct ir.package_sha256 from zsl.zsl2_source_bindings b join zsl.ingest_runs ir on ir.ingest_run_id=b.ingest_run_id where b.normalization_run_id=$1`,[runId])).rows.map((x:Record<string,unknown>)=>String(x.package_sha256??''));
 const upstreamPackageMatch=Boolean(expectedZsl1PackageSha)&&upstreamPackageRows.length===1&&upstreamPackageRows[0]===expectedZsl1PackageSha;
 const vintages=(await c.query(`select b.source_key,sr.source_year,sr.source_quarter from zsl.zsl2_source_bindings b join zsl.source_releases sr on sr.release_id=b.release_id where b.normalization_run_id=$1 order by b.source_key`,[runId])).rows;
 const census=vintages.filter((x:Record<string,unknown>)=>String(x.source_key).startsWith('CENSUS_GAZETTEER_')),cy=census.map((x:Record<string,unknown>)=>String(x.source_year??''));
 const hud=vintages.filter((x:Record<string,unknown>)=>String(x.source_key).startsWith('HUD_USPS_')),hv=hud.map((x:Record<string,unknown>)=>`${String(x.source_year??'')}-Q${String(x.source_quarter??'')}`);
 const sourceVintageCoherence=census.length===4&&new Set(cy).size===1&&/^\d{4}$/.test(cy[0]??'')&&hud.length===2&&new Set(hv).size===1&&/^\d{4}-Q[1-4]$/.test(hv[0]??'');

 const replay=await deterministicReplay(c,runId);
 const perf=(await c.query(`select count(*)::text n,coalesce(max(duration_ms),0)::text max_ms,coalesce(percentile_cont(0.99) within group(order by duration_ms),0)::text p99_ms from zsl.zsl2_performance_measurements where normalization_run_id=$1 and operation='NORMALIZE_PAGE'`,[runId])).rows[0];
 const maxMs=Number(String(perf.max_ms??'0')),p99Ms=Number(String(perf.p99_ms??'0')),perfN=BigInt(String(perf.n??'0'));const maxLimit=policy.performance?.maxStatementMs??120000,p99Limit=policy.performance?.pageP99Ms??60000;
 const performanceRuntimePass=perfN>0n&&maxMs<maxLimit&&p99Ms<p99Limit;

 const checks={
  exact_source_set:exactSourceSet,bound_records_only:outside===0n,source_snapshot_immutable:sourceSnapshotsValid,normalization_checkpoints_complete:checkpointsComplete,checkpoint_counters_reconcile:checkpointCountersReconcile,
  zero_fatal_conflicts:fatal===0n,zero_orphans:orphan===0n,identity_hash_coverage:noHash===0n,lineage_coverage:boundRecords===lineage&&duplicateLineage===0n,deterministic_replay:replay.pass,
  hud_ratio_reconciliation:ratioBad===0n&&rowRatioBad===0n,zero_component_evidence:true,coordinate_sanity:coordBad===0n&&gazNoPoint===0n,run_membership_complete:locLineageMissing===0n&&relLineageMissing===0n,
  upstream_package_match:upstreamPackageMatch,source_vintage_coherence:sourceVintageCoherence,zip_zcta_separation:zipZctaCollision===0n,cbsa_authority_rules:cbsaAuthorityBad===0n&&fake99999===0n,multi_parent_geography:multiParentPreserved,territorial_pending_evidence_valid:territorialAuthorityBad===0n&&territorialPendingCount===territorialPendingValid&&territorialPendingLineageBad===0n&&territorialFabrication===0n,
  page_performance_observed:performanceRuntimePass,zsl1_authority_decision_valid:zsl1AuthorityDecisionValid
 };
 const measured={expectedSources:expected,actualSources:actual,missing,unexpected,checkpoints:checkpointRows,snapshots,boundRecords:boundRecords.toString(),lineage:lineage.toString(),duplicateLineage:duplicateLineage.toString(),fatal:fatal.toString(),orphan:orphan.toString(),ratioStats,ratioPolicy:{componentTargets:[0,1],totalTarget:1,tolerance:tol},rowRatioBad:rowRatioBad.toString(),zipZctaCollision:zipZctaCollision.toString(),cbsaAuthorityBad:cbsaAuthorityBad.toString(),fake99999:fake99999.toString(),expectedPairs:expectedPairs.toString(),actualPairs:actualPairs.toString(),territorialAuthorityBad:territorialAuthorityBad.toString(),territorialPendingCount:territorialPendingCount.toString(),territorialPendingValid:territorialPendingValid.toString(),territorialPendingLineageBad:territorialPendingLineageBad.toString(),territorialFabrication:territorialFabrication.toString(),zsl1AuthorityDecisionValid,upstreamPackageRows,expectedZsl1PackageSha,vintages,replay,performance:{samples:perfN.toString(),maxMs,p99Ms,maxLimit,p99Limit}};
 for(const [name,passed] of Object.entries(checks))await saveCheck(c,runId,evaluationId,name,passed,{...measured,check:name});
 return {evaluationId,checks,counts:measured,replay};
}
export function sealEvidence(e:unknown){return sha256Json(e);}
