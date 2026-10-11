# Dependency Freeze Gate

The source package can be assembled offline, but production certification MUST use a fully resolved npm lock from an approved connected builder. The included lock preserves the declared direct versions only and intentionally fails `scripts/verify-lock.mjs` until all transitive `resolved` and `integrity` entries exist.

Before building the deployment ZIP:

```bash
./scripts/resolve-lock-connected.sh
```

Do not certify a deployment artifact whose lock verification fails.
