# Source Authority
ZSL3 consumes only exact, currently certified ZSL1 ingest runs and the currently active ZSL2 canonical geography authority. Source selection uses explicit dataset/geography metadata, not release-name substring guessing. Any upstream revocation makes `zsl.zsl3_current_authority` fail closed.
