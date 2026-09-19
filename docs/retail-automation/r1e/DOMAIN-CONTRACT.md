# R1E V2.1 Domain Contract

## Mission

R1E V2.1 is the authoritative exact-product and economic-observation qualification boundary between certified retail collection (R1D) and retail search/yield intelligence (R1F).

## R1E owns

- exact immutable product identity qualification
- hard variant mismatch rejection
- expected identifier comparison
- accessory/exclusion rejection
- allowed-condition enforcement
- observation-scoped duplicate suppression
- qualification confidence
- immutable reason/evidence production
- qualification currentness

## R1E does not own

- demand
- profitability
- ROI
- fees
- capital
- BUY/NO-BUY
- purchase
- checkout

## Identity authority

The exact product identity comes from the immutable R1A revision referenced by the dispatched R1C compilation:

```text
search_job_compilations.r1a_revision_id
search_job_compilations.r1a_revision_hash
            ↓
search_target_revisions
            ↓
recompute r1a_revision_business_document hash
```

R1E does not depend on a current mutable route to reconstruct historical product intent.

## Search term semantics

```text
required_identity_terms
    hard product identity

search_expansion_terms
    discovery/query expansion only
```

Legacy R1A `include_terms` are treated as search expansion unless the governed R1A `search_policy.required_identity_terms` explicitly declares a hard requirement.

## Observation identity

Product identity and observation identity are different.

An observation fingerprint is scoped to the collection, compilation/location/store context, source, product key and canonical offer/inventory state.

The raw scraper payload hash is retained in evidence, but is not part of duplicate identity.

## Downstream authority

R1F may consume only:

```sql
retail.r1e_effective_qualified_products
```

That view excludes:
- certification QA rows
- stale R1D bindings
- stale R1E certifications
- old engine versions
- non-reproducible evidence
- mismatched R1A/R1C authority
