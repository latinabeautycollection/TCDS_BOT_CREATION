import { createHash } from 'node:crypto';

export type BrightDataZoneCostBucket={
  accountKey:string;
  bucketKey:string;
  bandwidthBytes:string;
  billedCostUsd:string;
  raw:Record<string,unknown>;
};

export type BrightDataDailyResourceCost={
  costDay:string;
  resourceId:string;
  billedCostUsd:string;
};

export function canonicalStringify(value:unknown):string{
  if(value===null||typeof value!=='object') return JSON.stringify(value);
  if(Array.isArray(value)) return `[${value.map(canonicalStringify).join(',')}]`;
  const obj=value as Record<string,unknown>;
  return `{${Object.keys(obj).sort().map(k=>`${JSON.stringify(k)}:${canonicalStringify(obj[k])}`).join(',')}}`;
}

export function sha256Json(value:unknown):string{
  return createHash('sha256').update(canonicalStringify(value),'utf8').digest('hex');
}

const nonNegativeDecimal=/^(?:0|[1-9]\d*)(?:\.\d+)?$/;
const nonNegativeInteger=/^(?:0|[1-9]\d*)$/;

function decimalToScaled(value:string):bigint{
  if(!nonNegativeDecimal.test(value)) throw new Error(`Invalid decimal ${value}`);
  const [whole,fraction='']=value.split('.');
  if(fraction.length>8) throw new Error(`Decimal exceeds NUMERIC(18,8): ${value}`);
  return BigInt(whole)*100000000n+BigInt((fraction+'00000000').slice(0,8));
}

/**
 * Structural parser only. Monetary values intentionally remain decimal strings.
 * PostgreSQL NUMERIC is the only settlement arithmetic authority in V2.2.
 */
export function parseBrightDataZoneCost(payload:unknown):BrightDataZoneCostBucket[]{
  if(!payload||typeof payload!=='object'||Array.isArray(payload)){
    throw new Error('Bright Data /zone/cost response must be a JSON object');
  }
  const root=payload as Record<string,unknown>;
  const roots=Object.entries(root).filter(([,value])=>
    value!==null&&typeof value==='object'&&!Array.isArray(value)
  );
  const selected=root.ID&&typeof root.ID==='object'&&!Array.isArray(root.ID)
    ? ['ID',root.ID] as const
    : roots.length===1
      ? roots[0]
      : null;
  if(!selected){
    throw new Error(
      'Bright Data /zone/cost response must contain ID or one dynamic account object'
    );
  }
  const [accountKey,idNode]=selected;

  const buckets:BrightDataZoneCostBucket[]=[];
  for(const [bucketKey,rawValue] of Object.entries(idNode as Record<string,unknown>)){
    if(!rawValue||typeof rawValue!=='object'||Array.isArray(rawValue)) continue;
    const row=rawValue as Record<string,unknown>;
    const bw=String(row.bw);
    const cost=String(row.cost);
    if(!nonNegativeInteger.test(bw)||!nonNegativeDecimal.test(cost)){
      throw new Error(`Invalid /zone/cost bucket ${bucketKey}: ${JSON.stringify(row)}`);
    }
    buckets.push({
      accountKey,
      bucketKey,
      bandwidthBytes:bw,
      billedCostUsd:cost,
      raw:row
    });
  }
  if(!buckets.length) throw new Error('Bright Data /zone/cost response contained no usable cost buckets');
  return buckets.sort((a,b)=>a.bucketKey.localeCompare(b.bucketKey));
}

/**
 * Validates the provider's daily resource map and its optional aggregate total.
 * The total key is metadata and is never returned as a billable day.
 */
export function parseBrightDataCostBreakdown(
  payload:unknown,
  from:string,
  toExclusive:string
):BrightDataDailyResourceCost[]{
  validateDateRange(from,toExclusive);
  if(!payload||typeof payload!=='object'||Array.isArray(payload)){
    throw new Error('Bright Data cost breakdown response must be a JSON object');
  }
  const root=payload as Record<string,unknown>;
  const daily:BrightDataDailyResourceCost[]=[];
  const sums=new Map<string,bigint>();

  for(const [day,value] of Object.entries(root)){
    if(day==='total') continue;
    if(!/^\d{4}-\d{2}-\d{2}$/.test(day)||day<from||day>=toExclusive){
      throw new Error(`Invalid or out-of-range cost-breakdown day ${day}`);
    }
    if(!value||typeof value!=='object'||Array.isArray(value)){
      throw new Error(`Cost-breakdown day ${day} must map resources to billed USD`);
    }
    for(const [resourceId,rawCost] of Object.entries(value as Record<string,unknown>)){
      const billedCostUsd=String(rawCost);
      if(!nonNegativeDecimal.test(billedCostUsd)){
        throw new Error(`Invalid billed cost for ${day}/${resourceId}`);
      }
      daily.push({costDay:day,resourceId,billedCostUsd});
      sums.set(resourceId,(sums.get(resourceId)??0n)+decimalToScaled(billedCostUsd));
    }
  }

  if(root.total!==undefined){
    if(!root.total||typeof root.total!=='object'||Array.isArray(root.total)){
      throw new Error('Cost-breakdown total must map resources to billed USD');
    }
    const total=root.total as Record<string,unknown>;
    const resources=new Set([...sums.keys(),...Object.keys(total)]);
    for(const resourceId of resources){
      const declared=String(total[resourceId]??'0');
      if(!nonNegativeDecimal.test(declared)){
        throw new Error(`Invalid aggregate cost for total/${resourceId}`);
      }
      if(decimalToScaled(declared)!==(sums.get(resourceId)??0n)){
        throw new Error(`Cost-breakdown total mismatch for ${resourceId}`);
      }
    }
  }

  return daily.sort((a,b)=>
    a.costDay.localeCompare(b.costDay)||a.resourceId.localeCompare(b.resourceId)
  );
}

export function validateDateRange(from:string,toExclusive:string):void{
  if(!/^\d{4}-\d{2}-\d{2}$/.test(from)||!/^\d{4}-\d{2}-\d{2}$/.test(toExclusive)){
    throw new Error('from and to must be YYYY-MM-DD');
  }
  const f=new Date(`${from}T00:00:00Z`);
  const t=new Date(`${toExclusive}T00:00:00Z`);
  if(Number.isNaN(f.valueOf())||Number.isNaN(t.valueOf())||t<=f){
    throw new Error('Bright Data cost range requires exclusive to > from');
  }
}
