import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("source contracts cover every governed source",async()=>{
  const policy=JSON.parse(await readFile("config/source-policy.json","utf8"));
  const contracts=JSON.parse(await readFile("config/schema-contracts.json","utf8"));
  const keys=new Set(contracts.contracts.map((x:any)=>x.sourceKey));
  for(const k of Object.keys(policy.sources)) assert.ok(keys.has(k),`missing contract ${k}`);
});
