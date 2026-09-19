# R1E V2.1 — Final Green Tier 1 Certification Doctrine

## Implementation designation

R1E V2.1 is the final production implementation candidate for TCDS exact product identity and observation qualification.

## Runtime certification prerequisites

The exact release ZIP may receive `CERTIFIED / FREEZE APPROVED / SAFE FOR R1F` only when all of the following pass against QA:

- latest R1D certification is `r1d-v2.0.0 / CERTIFIED`
- exact R1D binding is current
- certified R1E ruleset hash reproduces
- certified immutable R1E policy hash reproduces
- at least 1,200 class-balanced deterministic fixtures satisfy Green Tier policy
- positive precision >= 98%
- positive recall >= 98%
- overall decision accuracy >= 98%
- overall false-positive rate <= 5%
- wrong-variant false-positive rate <= 1%
- duplicate accuracy >= 99.9%
- reason-family accuracy = 100%
- evidence coverage = 100%
- deterministic replay = 100%
- at least 100 E2E QA captures run through the real evaluator with 100% expected outcome accuracy
- full evaluator duplicate race test passes
- final adversarial suite passes
- exact release ZIP SHA is sealed
- deterministic and E2E fixture manifests are sealed
- final PostgreSQL certification row and ARB process-run terminal state commit atomically

Static review cannot substitute for the runtime PostgreSQL certification record.
