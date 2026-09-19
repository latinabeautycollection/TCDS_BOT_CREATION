# R1E Freeze Certification

R1E runtime certification is deliberately statistical and deterministic.

Default enterprise thresholds:
- at least 1,200 labeled fixtures
- at least 1,000 duplicate fixtures
- decision accuracy >= 98%
- false-positive rate <= 5%
- duplicate accuracy >= 99.9%
- evidence coverage = 100%
- rejection explainability coverage = 100%
- deterministic replay = 100%
- all adversarial gates PASS

The fixture population must include:
- positive identity
- wrong brand
- wrong model
- accessories
- condition mismatch
- duplicates
- incomplete captures
- bundle/variant examples

The engine is not `CERTIFIED / FREEZE APPROVED` merely because the package installs or the example fixtures pass.
