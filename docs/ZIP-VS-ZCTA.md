# ZIP vs ZCTA
ZCTA is Census statistical geography. ZBP is operational ZIP Code Business Patterns and must resolve to ZSL2 `postal_code` (`US:ZIP:<5-digit>`), never to ZCTA. ACS ZCTA facts remain attached to `US:ZCTA:<5-digit>`. No fallback between these authorities is permitted.
