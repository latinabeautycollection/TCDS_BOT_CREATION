import { config } from './config.js';
const levels={debug:10,info:20,warn:30,error:40} as const;
function clean(v:unknown):unknown{
  if(typeof v==='string') return v.replace(/Bearer\s+[A-Za-z0-9._-]+/gi,'Bearer [REDACTED]');
  if(Array.isArray(v)) return v.map(clean);
  if(v&&typeof v==='object'){
    const out:Record<string,unknown>={};
    for(const [k,x] of Object.entries(v as Record<string,unknown>)) out[k]=/token|authorization|secret|password/i.test(k)?'[REDACTED]':clean(x);
    return out;
  }
  return v;
}
export function log(level:keyof typeof levels,message:string,meta:Record<string,unknown>={}){
  if(levels[level]<levels[config.LOG_LEVEL]) return;
  console.log(JSON.stringify({ts:new Date().toISOString(),level,message,...(clean(meta) as Record<string,unknown>)}));
}
