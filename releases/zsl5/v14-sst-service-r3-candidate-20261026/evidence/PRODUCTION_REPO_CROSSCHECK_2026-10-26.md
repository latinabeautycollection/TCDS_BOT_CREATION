# Production Repo Cross-check — 2026-10-26

Repository: `latinabeautycollection/TCDS_BOT_CREATION`
Observed main HEAD: `ef985e28f41a56b5b5d25252aacdb1ab456888b0` (`Isolate ZSL governance trigger row types`).

Observed at review time:
- no 042+ migrations in current repo
- no `apps/zsl-tax-intelligence` path
- production root uses ESM, ES2022, Node 22-compatible TypeScript, `pg`, `tsx`
- root `tsconfig.json` compiles `apps/**/*.ts`

The repo overlay is additive and places runtime code under `apps/zsl-tax-intelligence`, migrations under `database/migrations`, and source acquisition tooling under `tools/zsl-tax-source-acquisition`.

No tax migration in the package mutates `retail.*`, `arb.*`, `pqp.*`, or `cax.*`.
