# ACS Metadata Authority

ZSL3 never fabricates ACS variable semantics and never looks for variable metadata among ACS observation records.

The authority path is:

`ZSL1 schema_validation_runs -> validation_document.evidence.variableMetadata -> ZSL3 metadata binding`.

ZSL3 binds the exact ZSL1 ingest run, artifact, schema-validation run, metadata SHA, dataset vintage, variable code, label, concept and predicate type. Missing or contradictory metadata fails closed.

The V2.2 ACS source policy binds population, median household income, poverty percentage, and housing units. Per-capita income (`DP03_0088E`) is deferred because the certified 2024 ACS STATE, COUNTY, PLACE, and ZCTA schema validations do not contain its variable metadata. It is not an input to any V2.2 derived formula. Adding it later requires certified upstream metadata and a newly sealed ZSL3 policy package.

The source policy also carries one explicit vintage crosswalk: ACS 2024 PLACE GEOID `0127640` resolves to the current certified canonical key `US:PLACE:0127604`. Census TIGERweb's ACS24 table identifies `0127640` as Fort Rucker with ANSI place code `02402503`; its current ACS26 table identifies `0127604` as Fort Novosel with the same ANSI code and matching internal-point coordinates. The mapping is exact by source key, source vintage, geography type, and source GEOID; it does not use name matching. The raw ACS record and 2024 source vintage remain on each fact's lineage.

Authority references:

- https://tigerweb.geo.census.gov/tigerwebmain/Files/bas25/tigerweb_bas25_cdp_2024_acs24_al.html
- https://tigerweb.geo.census.gov/tigerwebmain/Files/acs26/tigerweb_acs26_cdp_al.html
