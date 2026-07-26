# Milestone 1B.4 Green Tier 1 — Controlled Execution Engine v0.7.0

This release is a control-plane executor for the owned TCDS PQP laboratory. It
does not carry high-volume browser, Envoy, Suricata, or behavioral telemetry.

Security properties:
- production policy contains no shell or interpreter command
- strict request validation occurs before path construction or lock acquisition
- caller identifiers are never used as physical filenames; SHA-256 digests are
  used for component and idempotency locks
- intermediate symlinks are rejected and protected files are opened O_NOFOLLOW
- executable path, package identity metadata, owner, group, mode, inode, device,
  and SHA-256 are pinned in an installation-time trust manifest
- output is streamed and bounded while the child runs
- all decisions emit audit events; policy can fail closed if audit is unavailable
- receipts form a SHA-256 chain and can be HMAC-authenticated
- IN_PROGRESS journals are fsynced before launch and reconciled after crashes
- children receive PR_SET_PDEATHSIG, PR_SET_NO_NEW_PRIVS, resource limits,
  cleared supplementary groups, fixed UID/GID, fixed umask, and immutable env
- protected stdin is delivered through an inherited descriptor; only its digest
  is stored
- every retry attempt and total elapsed time are recorded

Host-specific certification still requires production-equivalent tests on the
upgraded Linode, AppArmor/systemd sandbox activation, and a configured remote
immutable receipt destination. No local-only framework can make root-level
tampering impossible.
