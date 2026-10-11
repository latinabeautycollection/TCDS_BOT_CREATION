# ACS Metadata Authority

ZSL3 never fabricates ACS variable semantics and never looks for variable metadata among ACS observation records.

The authority path is:

`ZSL1 schema_validation_runs -> validation_document.evidence.variableMetadata -> ZSL3 metadata binding`.

ZSL3 binds the exact ZSL1 ingest run, artifact, schema-validation run, metadata SHA, dataset vintage, variable code, label, concept and predicate type. Missing or contradictory metadata fails closed.
