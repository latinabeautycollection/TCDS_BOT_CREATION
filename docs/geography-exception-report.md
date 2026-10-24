# CBP/ZBP geography exception report

This is a read-only audit of the pinned CBP and ZBP releases against the current certified ZSL2 canonical locations. It emits one JSON line per unmatched or explicitly excluded source record, followed by a summary for each dataset. It does not update ZSL1, ZSL2, ZSL3, or the certification decision.

After review and deployment of this source, run from the package root with the normal read-only database credentials and TLS settings:

```sh
npm run build
ZSL3_ZBP_RELEASE_ID=ace731d1-c607-4aac-b09d-959e1bbb341f \
ZSL3_HUD_RELEASE_KEY=2025-Q4 \
  node dist/src/cli/geography-exceptions.js > geography-exceptions.jsonl
```

Do not send the output to a public channel without review. It contains source record IDs and hashes but no raw record body. A `BLOCKED` summary means at least one unmatched row or exclusion-count mismatch requires investigation; `NOT_ASSESSED` is not a certification pass.

The comparison uses the stored HUD-USPS 2025-Q4 ZIP-to-county snapshot; it is not a complete USPS ZIP authority. A HUD non-match is not proof that USPS considers the ZIP invalid. Following the approved business disposition, this ZSL3 candidate pins 331 non-matching ZIPs and 2,030 certified ZBP source records as explicit exclusions from ZSL3 facts, while leaving ZSL1 source records unchanged. It also pins 10,525 certified CBP `COUNTY=999` aggregate records, which are not county facts. The reviewed ZIP CSV is `evidence/ZBP_HUD_2025Q4_NONMATCHES.csv`; its SHA-256 and release ID are pinned in `config/source-policy.json`. These dispositions do not waive any other runtime or certification check.
