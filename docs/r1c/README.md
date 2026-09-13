# TCDS Retail R1C V3 — GREEN TIER 1 SCRAPER AUTHORITY ALIGNED FREEZE FINAL

R1C V3 is the deterministic Search Job Compiler aligned to the R1B V4 existing-scraper execution authority.

## Required upstream authority

R1C V3 will not install/certify unless:

- `retail.r1b_schema_state.schema_version = 3.0.0`
- `retail.r1b_scraper_authority_state.hardening_version = 4.0.0`
- latest R1B certification is `r1b-v4.0.0`
- latest R1B certification status is `CERTIFIED`
- `retail.r1b_adapter_execution_ready(uuid)` exists

## Install order

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1   -f database/migrations/036_r1c_search_job_compiler_v2.sql

psql "$DATABASE_URL" -v ON_ERROR_STOP=1   -f database/migrations/036b_r1c_v3_scraper_authority_alignment.sql
```

## Bind latest R1B V4 certification

```bash
npx tsx scripts/retail-automation/r1c/bind-r1b-certification.ts   <latest_r1b_v4_certification_run_uuid> "R1C Approver"
```

This uses the governed `retail.r1c_bind_r1b_certification()` authority and preserves binding history.

## Register V3 compiler

```bash
npx tsx scripts/retail-automation/r1c/register-compiler.ts   scripts/retail-automation/r1c/compile-route.ts   database/migrations/036_r1c_search_job_compiler_v2.sql   database/migrations/036b_r1c_v3_scraper_authority_alignment.sql   3   "R1C Compiler Registrar"
```

## Certify V3 compiler

```bash
npx tsx scripts/retail-automation/r1c/certify-compiler.ts   <compiler_uuid> ./evidence/r1c-v3-compiler-qa.json "QA Approver"
```

The V3 compiler certificate binds:
- TypeScript wrapper SHA
- V2 migration SHA
- V3 hardening migration SHA
- normalized job function SHA
- adapter payload function SHA
- compile-route function SHA
- compilation-currentness function SHA
- query builder function SHA
- input-contract validator SHA
- scraper-authority reader SHA
- R1B-binding currentness function SHA
- compile-profile document SHA
- compiler-contract SHA
- QA-evidence SHA

## Create compile profile

`required_fields` from the certified R1B scraper contract are mandatory minimums.
The caller can only add stricter requirements.

```bash
npx tsx scripts/retail-automation/r1c/create-compile-profile.ts   <route_uuid> store_inventory extra_field1,extra_field2 "R1C Profile Service"
```

## Compile route

```bash
npx tsx scripts/retail-automation/r1c/compile-route.ts   <route_uuid> <profile_uuid> <compiler_uuid>
```

## Runtime R1D trust check

```bash
npx tsx scripts/retail-automation/r1c/assert-r1d-runtime-contract.ts   <compilation_uuid>   /path/to/TCDS_BOT_CREATION   scripts/retail-automation/r1c/compile-route.ts   database/migrations/036_r1c_search_job_compiler_v2.sql   database/migrations/036b_r1c_v3_scraper_authority_alignment.sql   /path/to/TCDS_Retail_R1C_GREEN_TIER1_HARDENED_V3_SCRAPER_AUTHORITY_ALIGNED_FREEZE_FINAL.zip
```

R1D must pass all three runtime authorities before dispatch:
1. R1B V4 retailer scraper file/package-tree attestation
2. R1C V3 compiler artifact/function attestation
3. latest R1C V3 package certification attestation

## Final certification

```bash
R1C_PACKAGE_SHA256=<exact_zip_sha256> npx tsx scripts/retail-automation/r1c/certify.ts <compiler_uuid>
```

Certification requires:
- current R1B V4 binding
- current V3 compiler authority
- nonempty effective compiled jobs
- at least one package-tree scraper fixture
- all 56 V3 adversarial gates pass
- deterministic replay of every effective job
- explicit scraper asset/contract evidence in every job
- sealed evidence manifest

## Authority boundary

```text
R1A = WHAT
R1B V4 = WHERE + EXACT EXISTING SCRAPER AUTHORITY
R1C V3 = EXACT DETERMINISTIC SCRAPER INSTRUCTION
R1D = WHEN / BUDGET / DISPATCH
```

R1C contains no schedule, budget, lease, dispatch, purchase or checkout authority.
