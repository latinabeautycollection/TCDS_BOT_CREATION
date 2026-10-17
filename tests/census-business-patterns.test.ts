import assert from "node:assert/strict";
import test from "node:test";
import { CensusBusinessPatternsAdapter, deriveCbpCountyGeoId, deriveCbpStateGeoId, isCbpStateAllEstablishments, isCbpCountyStateSummaryTotal } from "../src/adapters/census-business-patterns.adapter.js";

test("CBP state and county geographies derive from official FIPS columns",()=>{
  assert.equal(deriveCbpStateGeoId({STATE:"1"}),"0400000US01");
  assert.equal(deriveCbpCountyGeoId({STATE:"1",COUNTY:"1"}),"0500000US01001");
  assert.equal(deriveCbpStateGeoId({}),undefined);
  assert.equal(deriveCbpCountyGeoId({STATE:"01"}),undefined);
});


test("CBP NAICS fixed-width aggregate encodings are governed",()=>{
  const adapter = new CensusBusinessPatternsAdapter("STATE", 2023, "https://www2.census.gov/source.zip");
  for (const code of ["------", "11----", "113///", "1131//", "11311/", "443142"]) {
    assert.equal(adapter.validateRecord({ naturalKey: code, record: { GEO_ID: "0400000US01", NAICS2017: code, ESTAB: "1" } }).valid, true);
  }
  assert.equal(adapter.validateRecord({ naturalKey: "bad", record: { GEO_ID: "0400000US01", NAICS2017: "113//-", ESTAB: "1" } }).valid, false);
});


test("CBP state retains only the Census all-establishments LFO total",()=>{
  assert.equal(isCbpStateAllEstablishments({LFO:"-"}),true);
  assert.equal(isCbpStateAllEstablishments({LFO:"C"}),false);
  assert.equal(isCbpStateAllEstablishments({}),false);
});


test("CBP county retains only all-industries state-summary totals",()=>{
  assert.equal(isCbpCountyStateSummaryTotal({COUNTY:"999",NAICS2017:"------"}),true);
  assert.equal(isCbpCountyStateSummaryTotal({COUNTY:"999",NAICS2017:"48----"}),false);
  assert.equal(isCbpCountyStateSummaryTotal({COUNTY:"001",NAICS2017:"48----"}),true);
});
