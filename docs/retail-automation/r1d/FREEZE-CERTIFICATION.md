# R1D Freeze Certification

Static implementation quality is not runtime certification.

A legitimate GREEN TIER 1 freeze requires this exact release to pass in QA with real R1A/R1B/R1C authority.

Required evidence:

- latest R1C certification is `r1c-v3.0.0 / CERTIFIED`
- R1D bound to that exact certification
- at least one current dispatch binding
- GLOBAL daily budget policy
- cost profiles covering the production source set
- schedule policies covering production compiled jobs
- synchronized scheduling state
- due dispatch-job fixtures
- all 55 adversarial gates pass
- concurrent worker claim test passes
- no duplicate leases
- binding/platform concurrency limits hold
- budget reservations are released after QA concurrency cleanup
- no stale effective jobs
- no active budget/rate-limit violations
- evidence manifest SHA reproduces
- production rollback tested without deleting forensic evidence
