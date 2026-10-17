import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("source contracts cover every governed source",async()=>{
  const policy=JSON.parse(await readFile("config/source-policy.json","utf8"));
  const contracts=JSON.parse(await readFile("config/schema-contracts.json","utf8"));
  const keys=new Set(contracts.contracts.map((x:any)=>x.sourceKey));
  for(const k of Object.keys(policy.sources)) assert.ok(keys.has(k),`missing contract ${k}`);
});

test("freight cohort contracts bind the ZSL3 business-pattern prerequisites",async()=>{
  const policy=JSON.parse(await readFile("config/source-policy.json","utf8"));
  const contracts=JSON.parse(await readFile("config/schema-contracts.json","utf8"));
  assert.equal(policy.version,"2.1.7");
  const byKey=new Map<string,any>(contracts.contracts.map((x:any)=>[x.sourceKey,x]));
  for(const key of ["BTS_FAF6_ZONE_LOOKUP","BTS_SCTG_METADATA","CENSUS_CBP","CENSUS_ZBP"]){
    const contract=byKey.get(key);assert.ok(contract,`missing ${key}`);assert.ok(["2.1.1","2.1.2","2.1.3","2.1.7"].includes(contract.contractVersion));assert.ok(contract.required.length>0);
  }
  assert.equal(byKey.get("CENSUS_CBP").contractVersion,"2.1.7");
  assert.equal(byKey.get("CENSUS_ZBP").contractVersion,"2.1.7");
  assert.deepEqual(policy.sources.BTS_FAF6_ZONE_LOOKUP.expectedContentTypes,["xlsx","octet-stream"]);
});
