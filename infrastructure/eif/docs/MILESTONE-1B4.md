# Milestone 1B.4 — Controlled Execution Engine

This milestone adds a deny-by-default, JSON-request execution boundary. It never uses a shell, never accepts a command string, and executes only named commands registered in policy. It supports deterministic dry-run receipts, component serialization, idempotency keys, bounded output, clean environment construction, child resource limits, no-new-privileges, explicit timeout handling, and retries only for commands declared both retryable and idempotent.

The engine never kills or signals unrelated processes. Timeout termination is restricted to the process group created for the requested child. No package, service, firewall, Envoy, NGINX, Redis, or active PQP changes are performed by this milestone.

The initial allowlist contains only harmless framework/test commands. Package and service-management commands remain forbidden until their dedicated component contracts, validators, backups, and rollback modules are approved.
