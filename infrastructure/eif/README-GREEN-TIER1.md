# TCDS EIF 0.3.0 — Green Tier 1 Configuration Foundation

Run `install-green-tier1-upgrade.sh` against the existing EIF root. The installer
takes a complete framework backup, stages the upgrade, runs the original tests
and the new enterprise test suite, then atomically overlays approved framework
files. It makes no service, package, firewall, port or process changes.
