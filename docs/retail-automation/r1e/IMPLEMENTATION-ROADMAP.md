# R1E Implementation Roadmap

1. R1D V2 receives real QA certification.
2. Install R1E migration.
3. Bind latest R1D V2 certification.
4. Ensure every production scraper reports `r1d_metrics.collection_run_id`.
5. Register R1E ruleset.
6. Load representative labeled QA corpus.
7. Certify ruleset structure/evidence.
8. Run batch qualification against QA captures.
9. Run R1E adversarial suite.
10. Run statistical/deterministic engine certification.
11. Freeze `r1e-v1.0.0`.
12. Permit R1F to consume only `retail.r1e_effective_qualified_products`.

Do not wire R1F to raw captures or directly to `r1e_qualification_results`.
