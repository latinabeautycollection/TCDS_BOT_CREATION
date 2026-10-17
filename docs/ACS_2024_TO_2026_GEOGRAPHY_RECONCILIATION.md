# ACS 2024 to ZSL2 2026 place reconciliation

The bound 2024 ACS PLACE release has 32,330 records. Against the active ZSL2
2026 certified canonical place population, 25 source GEOIDs remain unmatched
after the previously approved Fort Rucker/Fort Novosel crosswalk. This is a
source-vintage difference, not permission to infer identity from names.

The [2024 Census national place Gazetteer](https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2024_Gazetteer/2024_Gaz_place_national.zip)
(SHA-256 `cf262fc92b2326f7a8c62a89d156a60eb17d64d6d35f7a62310c43bb08972c06`)
and [2026 Census national place Gazetteer](https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2026_Gazetteer/2026_Gaz_place_national.zip)
(SHA-256 `af678e2d990827c89ee39b98c82de6e90b693c7361ff0e559ae3076670dd2863`)
were compared by ANSI identifier. Six of the 25 have a unique 2026 place with
the same ANSI identifier:

| 2024 GEOID | 2026 GEOID | ANSI |
| --- | --- | --- |
| 2226746 | 2226674 | 02402501 |
| 2226757 | 2226676 | 02402502 |
| 3020950 | 3066910 | 02408674 |
| 3929288 | 3908859 | 02398942 |
| 4826736 | 4826666 | 02408241 |
| 5129152 | 5129098 | 02389108 |

The remaining 19 have no same-ANSI entry in the 2026 national place file.
They are pinned as exact, release-specific `NO_CURRENT_ANSI_SUCCESSOR`
exceptions in `config/source-policy.json`. Their raw ZSL1 records are retained.
No current-location feature fact is created for them, and no name-based or
spatially guessed successor is assigned.

Before normalization, the builder audits every bound ACS, CBP, and ZBP record
against current certified canonical locations. It fails before fact writes if
there is an unapproved mismatch, a missing crosswalk target, or an approved
exception that no longer matches the source population. During normalization,
each approved exception produces an immutable `WARN` conflict with its raw
record ID, source SHA, GEOID, ANSI identifier, and source-file hashes.

The `acs_geography_reconciled` runtime check requires every bound ACS record
to have either all four source facts or one exact approved warning, with no
overlap or missing records. It is required by the database certification guard.
This is a staging candidate until the preflight, build, runtime checks, and
rollback evidence pass on staging. It does not confer production authority.
