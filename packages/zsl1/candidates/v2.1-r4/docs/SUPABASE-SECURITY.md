# Supabase Security

ZSL1 uses a direct PostgreSQL connection, not anonymous browser credentials.

`zsl_raw` is revoked from PUBLIC. Application clients must not mutate raw evidence.

Recommended execution principals:
- `zsl_ingest_worker`
- `zsl_normalizer`
- `zsl_reader`
- `zsl_certifier`

If Supabase-managed permissions prevent role creation in migration, provision the roles using the database owner and re-run grants. Do not weaken the policy by granting `anon` or broad `authenticated` mutation rights.
