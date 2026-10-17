# Offline build note

This artifact was assembled in an offline build environment. `package.json` pins exact direct dependency versions.
`package-lock.json` records those exact direct versions, but the deployment engineer must run `npm install --package-lock-only`
in the approved connected build environment and review the resulting transitive dependency tree before the runtime freeze.
The regenerated lock SHA and SBOM must be bound into the runtime certification evidence.

Do not treat the offline lock as a supply-chain freeze by itself.
