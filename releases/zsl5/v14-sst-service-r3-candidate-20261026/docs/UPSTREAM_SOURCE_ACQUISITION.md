# Upstream source acquisition

The `tools/zsl-tax-source-acquisition` directory is a preserved standalone reference/operational tool from the ZSL1 V1.1 source-acquisition package. It is **not part of the TCDS_BOT_CREATION merge overlay** and is not in the ZSL5 runtime trust path. Its old ZSL1 loader/certifier code was deliberately excluded.

Production authority begins only after normalized records enter `apps/zsl-tax-intelligence/src/zsl1/source-ingest.ts`, which independently enforces the deployed ZSL1 release/artifact/raw-record/membership/schema/reconciliation/replay/certification lifecycle.

Before deploying the standalone acquisition tool on a host, generate and review its package lock from the exact pinned package.json in that environment. This does not block the repo-overlay build because the current production repo already has every dependency required by `apps/zsl-tax-intelligence` (Node/TypeScript/pg).
