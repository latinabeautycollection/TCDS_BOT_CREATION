# ZSL2 V2.1.2 Performance Certification Requirements

The prior production issue was a HUD ZIP-CBSA relationship statement exceeding Supabase's two-minute statement timeout. Performance is therefore a mandatory certification dimension, not advisory hardening.

The normalizer uses exact keyset paging, page-scoped transactions, a per-run/source advisory transaction lock, UNNEST staging for HUD relationship pages, set-based relationship/membership/lineage writes, durable checkpoints and resumability. The runtime gate nevertheless requires measured PostgreSQL evidence.

Capture total/source/page runtime, rows/s, relationships/s, P50/P95/P99/max page duration, CPU/memory/connections, buffers, WAL, temp bytes, disk IO, locks/deadlocks/timeouts, checkpoint overhead and query plans. Benchmark candidate page sizes. Reject query shapes with unjustified large sequential scans, nested-loop blowups, temp spills or cardinality errors.

Package SLOs: no normal statement timeout; P99 page <60 seconds; max page <120 seconds; no deadlocks; no source-wide transaction; no production instability. These are fail-closed inputs to `postgres_performance_runtime_pass`.
