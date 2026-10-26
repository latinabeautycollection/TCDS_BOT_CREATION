# Runtime Tax Content Status

This package contains the production population/certification machinery and official-source execution plan. It intentionally does **not** claim that all 1,071 national tax-family cells are already populated or certified.

The first live run must populate evidence from official sources and leave unfilled cells as NOT CERTIFIED. Golden/adversarial fixtures start in `EVIDENCE_REQUIRED` state so a build cannot self-certify using expectations derived from its own output.

Initial preferred execution wave:
- SST member jurisdictions
- Georgia reference path
- Virginia / Maryland / District of Columbia
- Texas / California / Washington / Colorado

Then high-complexity and remaining non-SST states.
