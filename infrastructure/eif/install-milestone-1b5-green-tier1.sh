#!/usr/bin/env bash
set -Eeuo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"; [[ "$T" == /* && ! -L "$T" ]] || exit 3
python3 "$S/release/verify_release_v0.9.0.py" "$S"
install -d -m 0750 "$T/state/locks"; exec 9>"$T/state/locks/framework-global-write.lock"; flock -n 9 || exit 7
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"; B="$T/backups/framework-upgrade/$STAMP"; install -d -m 0750 "$B/files"
python3 "$S/release/create_upgrade_plan_v0.9.0.py" "$S" "$T" "$B"
ST="$(mktemp -d)"; trap 'rc=$?; rm -rf "$ST"; exit $rc' EXIT; cp -a "$T/." "$ST/"; python3 "$S/release/apply_plan_v0.9.0.py" "$S" "$ST" "$B/plan.json" apply
"$ST/tests/state_v2/test-all.sh"
if ! python3 "$S/release/apply_plan_v0.9.0.py" "$S" "$T" "$B/plan.json" apply || ! "$T/tests/state_v2/test-all.sh"; then python3 "$S/release/apply_plan_v0.9.0.py" "$S" "$T" "$B/plan.json" rollback; exit 1; fi
echo "Milestone 1B.5 Green Tier 1 installed; backup: $B"
