# ZSL1 Source Authority — Verified Freeze Contracts

## Census Gazetteer

Authority: U.S. Census Bureau Gazetteer. Gazetteer files provide geographic identifiers, names where the geography has a name, area measurements, and representative internal latitude/longitude. ZCTA record layouts use `GEOID`/`GEOIDFQ` and do not require a fabricated `NAME` field. The parser accepts the current tab/pipe-delimited national-file variants but validates the actual header before loading.

Official references:
- https://www.census.gov/geographies/reference-files/time-series/geo/gazetteer-files.html
- https://www.census.gov/programs-surveys/geography/technical-documentation/records-layout/gaz-record-layouts.html

## HUD-USPS Crosswalk

Authority: HUD USER crosswalk derived from USPS administrative address data. API type 2 is ZIP→County and type 3 is ZIP→CBSA. `year` and `quarter` are explicit release parameters. The documented result structure uses fields including `zip`/`geoid`, `res_ratio`, `bus_ratio`, `oth_ratio`, and `tot_ratio`; the release envelope supplies year, quarter and crosswalk type.

Official reference:
- https://www.huduser.gov/portal/dataset/uspszip-api.html

## Census ACS 5-Year Data Profiles

Authority: Census Data API `/acs/acs5/profile`. The package binds each requested variable to its vintage-specific Census variable metadata (`label`, `concept`, `predicateType`, `group`) rather than assuming variable meaning from a hard-coded identifier alone. State, county, place and ZCTA profiles are supported by the 2024 profile examples.

Official references:
- https://www.census.gov/data/developers/data-sets/acs-5year.html
- https://api.census.gov/data/2024/acs/acs5/profile/examples.html

## BEA Regional RPP

Authority: Bureau of Economic Analysis Regional dataset. RPP measures price-level differences across states and metropolitan areas. The adapter binds requested year, table, line code and geography and verifies that the requested table appears in BEA Regional metadata.

Official references:
- https://www.bea.gov/data/prices-inflation/regional-price-parities-state-and-metro-area
- https://apps.bea.gov/api/_pdf/bea_web_service_api_user_guide.pdf

## BTS FAF6

Authority: Bureau of Transportation Statistics Freight Analysis Framework 6. FAF6 is benchmarked to the 2022 Commodity Flow Survey and provides weight/value flows by origin, destination, commodity and mode. The package does not silently scrape and activate a newer major release: a governed FAF6 Regional URL must be supplied.

Official references:
- https://www.bts.gov/faf
- https://rosap.ntl.bts.gov/view/dot/92758
