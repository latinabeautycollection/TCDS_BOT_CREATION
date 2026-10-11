import fs from'node:fs';import path from'node:path';import{sha256Text}from'./hash.js';import type{PolicyBundle}from'./types.js';
function load(name:string){const p=path.resolve(process.cwd(),'config',name);const raw=fs.readFileSync(p,'utf8');return{value:JSON.parse(raw),sha:sha256Text(raw)}}
export function loadPolicies():PolicyBundle{
 const s=load('source-policy.json'),f=load('feature-policy.json'),c=load('confidence-policy.json'),
 fr=load('freshness-policy.json'),n=load('naics-policy.json'),u=load('upstream-bindings.json'),cp=load('certification-policy.json');
 return{source:s.value,feature:f.value,confidence:c.value,freshness:fr.value,naics:n.value,upstream:u.value,certification:cp.value,
 hashes:{source:s.sha,feature:f.sha,confidence:c.sha,freshness:fr.sha,naics:n.sha,upstream:u.sha,certification:cp.sha}}
}
