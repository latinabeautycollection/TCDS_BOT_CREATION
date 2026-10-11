import test from "node:test";
import assert from "node:assert/strict";
import { canonicalJson,sha256Canonical } from "../src/core/hash.js";

test("canonical JSON is deterministic across key order",()=>{
  const a={b:2,a:1,n:{z:3,y:2}};
  const b={n:{y:2,z:3},a:1,b:2};
  assert.equal(canonicalJson(a),canonicalJson(b));
  assert.equal(sha256Canonical(a),sha256Canonical(b));
});
