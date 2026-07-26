# Milestone 1B.6 Green Tier 1 v1.1.0

This hardening release separates configuration recovery from forensic-evidence
preservation and adds fail-closed controls for encryption, HMAC authentication,
strict runtime schemas, component locking, staged backup commits, blob
reference counting, two-person production restore approval, application and
component gates, transaction linkage, immutable-export receipts, exact restore
planning, metadata capture, and recovery reconciliation.

## Production prerequisites

The engine intentionally refuses authoritative production operations until the
following externally governed controls are configured:

1. `EIF_BACKUP_HMAC_KEY` from an approved secret provider.
2. `EIF_APPROVAL_HMAC_KEY` from an approval authority.
3. An encryption hook and protected key reference for secret/private-key data.
4. An immutable remote-export hook that returns retention and object-version
   attestation.
5. Valid Milestone 1B.5 transactions for production backups.
6. Real Envoy, Suricata, and PQP validation receipts/gates.

These cannot be embedded safely in a generic archive because they require the
organization's own credentials, storage tenancy, operator identities, and
change-management system.
