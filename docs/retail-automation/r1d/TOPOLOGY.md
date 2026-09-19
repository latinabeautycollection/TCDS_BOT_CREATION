# R1 Multi-Retail Runtime Topology

```text
                CONTROL PLANE

R1A  Search Intent
 ↓
R1B  Retailer / Source / Store / ZIP / Existing Scraper Authority
 ↓
R1C  Exact Deterministic Scraper Payload
 ↓
R1D  Schedule / Geo Depth / Budget / Lease / Dispatch
 ↓
---------------------------------------------------------
                EXECUTION PLANE
Existing Best Buy worker
Existing Amazon package
Existing Target package
Existing Lowe's package
...
Existing certified retailer workers
 ↓
---------------------------------------------------------
                  DATA PLANE
collection_runs
raw_product_captures
retailer parsed tables
retail_products
price/inventory history
offer snapshots
evidence
```

R1D scales horizontally. Any number of dispatcher workers may compete for jobs because PostgreSQL lease acquisition uses row locks plus `SKIP LOCKED`.

Budget reservation is serialized through locked budget-policy rows.

Platform concurrency checks are serialized through transaction advisory locks.

R1D does not need retailer-specific business logic.
