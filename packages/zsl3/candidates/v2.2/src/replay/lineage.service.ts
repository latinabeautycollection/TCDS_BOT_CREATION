import type{PoolClient}from'pg';
export async function sourceInputsForDerived(c:PoolClient,derivedId:string):Promise<{role:string;vintage:string;confidence?:number}[]>{
 const q=await c.query<any>(`WITH RECURSIVE walk AS(
   SELECT fl.input_fact_id,fl.input_derived_feature_id FROM zsl.zsl3_feature_lineage fl WHERE fl.derived_feature_id=$1
   UNION ALL
   SELECT fl.input_fact_id,fl.input_derived_feature_id FROM walk w JOIN zsl.zsl3_feature_lineage fl ON fl.derived_feature_id=w.input_derived_feature_id WHERE w.input_derived_feature_id IS NOT NULL
 ) SELECT DISTINCT sf.source_role role,sf.source_vintage vintage FROM walk w JOIN zsl.zsl3_source_facts sf ON sf.fact_id=w.input_fact_id WHERE w.input_fact_id IS NOT NULL`,[derivedId]);
 return q.rows;
}
