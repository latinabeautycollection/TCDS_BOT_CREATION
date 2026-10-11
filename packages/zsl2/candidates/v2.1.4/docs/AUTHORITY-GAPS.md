# Deliberate Authority Gaps

## CBSA official names
Current ZSL1 V2.1 ingests HUD ZIP→CBSA codes but no Census/OMB CBSA name/delineation source. ZSL2 therefore creates code-only provisional CBSA identities and refuses to call their names authoritative. A future certified Census/OMB CBSA source must fill this gap before metro synchronization to R1B.

## USPS operational ZIP status
HUD-USPS crosswalk evidence proves a ZIP participated in a HUD-USPS relationship for a release; it does not replace the USPS Five-Digit ZIP product as operational ZIP authority. ZSL2 marks these `HUD_OBSERVED_PENDING_USPS`; ZSL3 must validate them.

## TIGER polygons
Current ZSL1 does not certify TIGER/Line artifacts. ZSL2 creates PostGIS geometry custody but does not fabricate polygon boundaries. Polygon authority starts only after certified TIGER evidence is available through ZSL1.

## HUD `99999` and Metropolitan Division semantics
HUD documents CBSA code `99999` as meaning the ZIP is not located within a CBSA. ZSL2 V2.1 preserves those ratios in `zsl.zsl2_postal_outside_cbsa_facts` and does not fabricate a CBSA `99999` location.

HUD also documents that, for metropolitan areas divided into Metropolitan Divisions, the crosswalk can report the Metropolitan Division code. Therefore HUD 5-digit area codes remain `HUD_CBSA_OR_METDIV_PENDING_OMB` until a certified Census/OMB delineation source classifies them as a CBSA or Metropolitan Division.
