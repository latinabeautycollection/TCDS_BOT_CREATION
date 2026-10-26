# Production Repo Overlay — V1.2.0 Final Freeze Candidate

Merge the contents of this directory into the root of `TCDS_BOT_CREATION` after confirming no migration-number drift occurred since the recorded repo cross-check.

Order:
1. Merge/apply 042a-d
2. 043/043a-c
3. 044a-b
4. 045/045a
5. 046a-c
6. **047a-c**
7. Build `apps/**/*.ts`
8. Run staging population/certification tests

Do not separately install older V1.0/V1.1 tax overlays after this package. They are retained only as historical development artifacts.

ZSL6 is not installed by this overlay. Future ZSL6 consumes `zsl.zsl5_zsl6_acquisition_cost_authority_v14` read-only.
