import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('registers unzip completion before consuming its output', async () => {
  const source = await readFile(
    new URL('../src/adapters/census-gazetteer.adapter.ts', import.meta.url),
    'utf8'
  );

  const completion = source.indexOf(
    'const completion=new Promise<number|null>'
  );
  const consumption = source.indexOf('for await(const line of rl)');
  const awaited = source.indexOf('const code=await completion');

  assert.ok(completion >= 0, 'completion promise is missing');
  assert.ok(consumption > completion, 'listener must precede stream consumption');
  assert.ok(awaited > consumption, 'completion must be awaited after consumption');
  assert.doesNotMatch(
    source,
    /await new Promise<number\|null>\(r=>cp\.on\('close',r\)\)/
  );
});
