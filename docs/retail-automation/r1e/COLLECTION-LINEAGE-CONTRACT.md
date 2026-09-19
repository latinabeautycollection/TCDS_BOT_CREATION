# R1D → R1E V2.1 Collection Lineage Contract

Every certified scraper execution used by R1E must report the `retail.collection_runs.id` associated with the returned records:

```json
{
  "r1d_metrics": {
    "collection_run_id": "00000000-0000-0000-0000-000000000000",
    "records_requested": 100,
    "records_collected": 97,
    "actual_cost_usd": 0.1455
  }
}
```

R1E V2.1 requires:

1. `raw_product_captures.collection_run_id` is present.
2. The referenced `retail.collection_runs` row exists.
3. `collection_runs.platform_id = raw_product_captures.platform_id`.
4. Exactly one successful R1D dispatch attempt reports that collection-run UUID.
5. The attempt's R1D job resolves to one immutable R1C compilation.
6. The compilation's R1A revision ID/hash resolves and recomputes exactly.

Zero matching attempts fail closed.

More than one matching successful attempt is contradictory provenance and also fails closed.

Malformed UUID values in worker metrics are ignored safely rather than crashing the intake query.

The exact completed R1D attempt evidence is copied into each R1E result and SHA-sealed.
