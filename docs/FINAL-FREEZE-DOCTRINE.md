# ZSL2 V2.1 Final Freeze Doctrine

A ZSL2 package is not production authority merely because its TypeScript and SQL compile.

The exact deployment artifact may become effective only after:
1. the dependency lock is fully resolved and integrity-sealed;
2. migrations install cleanly on the target Supabase/PostgreSQL instance;
3. exact ZSL1 V2.1 package identity is verified for every bound source ingest;
4. normalization reaches RECONCILED;
5. all immutable runtime checks pass;
6. certification inserts `CERTIFIED` for the same package/policy identity;
7. an explicit `ACTIVATED` authority event references the latest CERTIFIED run;
8. all bound ZSL1 ingest certifications remain currently CERTIFIED.

If a bound ZSL1 certification is later revoked or superseded, `zsl.zsl2_current_authority` fails closed and downstream certified views become empty until a new valid ZSL2 authority is activated.

R1B remains the retail search-authorization authority. ZSL2 emits only factual candidates/proposals.
