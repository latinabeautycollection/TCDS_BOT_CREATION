import test from "node:test";
import assert from "node:assert/strict";
import { redact } from "../src/core/redaction.js";

test("redacts direct secrets and connection passwords",()=>{
  const env:any={
    CENSUS_API_KEY:"census-secret-123",
    HUD_USER_TOKEN:"hud-secret-456",
    BEA_API_KEY:"bea-secret-789",
    DATABASE_URL:"postgresql://user:dbsecret@host/db"
  };
  const out=redact("https://x?key=census-secret-123 Bearer hud-secret-456 postgresql://user:dbsecret@host/db",env);
  assert.equal(out.includes("census-secret-123"),false);
  assert.equal(out.includes("hud-secret-456"),false);
  assert.equal(out.includes("dbsecret"),false);
  assert.match(out,/\[REDACTED\]/);
});
