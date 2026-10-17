import test from "node:test";import assert from "node:assert/strict";import { detectDelimiter,parseDelimitedLine } from "../src/core/delimited.js";
test('detects Census tab and pipe delimiter variants',()=>{assert.equal(detectDelimiter('USPS\tGEOID\tNAME'),'\t');assert.equal(detectDelimiter('USPS|GEOID|NAME'),'|')});
test('CSV parser handles quoted commas and escaped quotes',()=>{assert.deepEqual(parseDelimitedLine('a,"b,c","d""e"',','),['a','b,c','d"e'])});
