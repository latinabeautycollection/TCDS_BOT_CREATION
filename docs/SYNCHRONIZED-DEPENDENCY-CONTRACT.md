# ZSL2 V2.1 Synchronized Dependency Contract

## Authoritative identity

- Package: `TCDS_ZSL2_GREEN_TIER1_CANONICAL_GEOGRAPHY_V2_1_FREEZE_FINAL`
- Package release: `2.1.0`
- Schema version: `2.1.0`
- Runtime engine: `zsl2-v2.1.0`
- Upstream ZSL1: exact package SHA binding is mandatory.
- Downstream ZSL3 and ZSL4: exact ZSL2 package SHA plus runtime engine `zsl2-v2.1.0` are mandatory.

## Freeze rule

Package release, schema version, runtime engine, manifests, and downstream bindings are one atomic contract. A change to any sealed ZSL2 source file changes the ZSL2 package SHA and requires ZSL3 and ZSL4 bindings to be resealed.

## Installation order

1. ZSL1 source freeze and runtime certification.
2. ZSL2 exact-package installation and runtime certification.
3. ZSL3 build/certification against the current ZSL2 authority.
4. ZSL4 build/certification against the current ZSL2 and ZSL3 authorities.

## Fail-closed requirements

- ZSL2 must reject missing/revoked ZSL1 authority.
- ZSL3 must reject a ZSL2 package SHA or engine mismatch.
- ZSL4 must reject a ZSL2 package SHA or engine mismatch and, when ZSL3 features are used, a ZSL3 package SHA or engine mismatch.
- No downstream package may infer engine identity from a filename.
