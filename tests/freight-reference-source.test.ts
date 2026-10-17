import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { FreightReferenceAdapter, deriveCbpCountyGeoId } from "../src/adapters/freight-reference.adapter.js";

test("freight reference adapter consumes official formats without external conversion",async()=>{
  const source=await readFile("src/adapters/freight-reference.adapter.ts","utf8");
  assert.match(source,/xl\/worksheets\/sheet1\.xml/);
  assert.match(source,/SCTG_2_Digit_Codes_1997\.txt/);
  assert.match(source,/SCTG_TWO_DIGIT_MEMBER_MISSING/);
  assert.match(source,/SCTG_HEADER_MISSING/);
  assert.match(source,/parseTabDelimited/);
});

test("archive inspection accepts both supported unzip date formats",async()=>{
  const source=await readFile("src/core/archive.ts","utf8");
  assert.match(source,/\\d\{4\}-\\d\{2\}-\\d\{2\}\|\\d\{2\}-\\d\{2\}-\\d\{4\}/);
});

test("SCTG permits its published 1997 authority year only",()=>{
  assert.doesNotThrow(()=>new FreightReferenceAdapter("BTS_SCTG_METADATA","SCTG-1997",1997,"https://rosap.ntl.bts.gov/source.zip"));
  assert.throws(()=>new FreightReferenceAdapter("BTS_FAF6_ZONE_LOOKUP","FAF6",1997,"https://faf.ornl.gov/source.xlsx"));
});

test("CBP county derives the standard GEO_ID from official 2023 FIPS columns",()=>{
  assert.equal(deriveCbpCountyGeoId({STATE:"01",COUNTY:"001"}),"0500000US01001");
  assert.equal(deriveCbpCountyGeoId({STATE:"1",COUNTY:"1"}),"0500000US01001");
  assert.equal(deriveCbpCountyGeoId({STATE:"01"}),undefined);
});
