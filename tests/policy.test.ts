import test from "node:test";
import assert from "node:assert/strict";
import { loadPolicy } from "../src/core/policy.js";

test("all source policies have bounded retry and artifact ceilings",async()=>{
  const {doc,sha256}=await loadPolicy("config/source-policy.json");
  assert.match(sha256,/^[0-9a-f]{64}$/);
  for(const [key,p] of Object.entries(doc.sources)){
    assert.equal(key,p.sourceKey);
    assert.ok(p.maxArtifactBytes>0);
    assert.ok(p.maxExpandedBytes>=p.maxArtifactBytes);
    assert.ok(p.retry.attempts>=1 && p.retry.attempts<=10);
    assert.ok(p.allowedHosts.length>0);
  }
});
