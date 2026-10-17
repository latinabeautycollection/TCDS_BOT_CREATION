import test from "node:test";
import assert from "node:assert/strict";
import { readdir } from "node:fs/promises";

test("package contains no Python cache artifacts",async()=>{
  const all=await readdir(".", {recursive:true});
  assert.equal(all.some(x=>x.includes("__pycache__")||x.endsWith(".pyc")),false);
});
