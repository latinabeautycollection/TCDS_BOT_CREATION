declare const process: any;
declare const console: any;
declare module 'node:fs' { const x:any; export default x; }
declare module 'node:path' { const x:any; export default x; }
declare module 'node:crypto' { export function createHash(...args:any[]):any; }
declare module 'node:test' { const test:any; export default test; }
declare module 'node:assert/strict' { const assert:any; export default assert; }
