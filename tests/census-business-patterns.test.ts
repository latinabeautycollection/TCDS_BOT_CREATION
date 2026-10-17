import assert from "node:assert/strict";
import test from "node:test";
import { deriveCbpCountyGeoId, deriveCbpStateGeoId } from "../src/adapters/census-business-patterns.adapter.js";

test("CBP state and county geographies derive from official FIPS columns",()=>{
  assert.equal(deriveCbpStateGeoId({STATE:"1"}),"0400000US01");
  assert.equal(deriveCbpCountyGeoId({STATE:"1",COUNTY:"1"}),"0500000US01001");
  assert.equal(deriveCbpStateGeoId({}),undefined);
  assert.equal(deriveCbpCountyGeoId({STATE:"01"}),undefined);
});
