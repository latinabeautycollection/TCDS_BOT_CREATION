#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'; umask 027
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
[[ "$T" == /* && ! -L "$T" && -x "$T/bin/eif-state-v2" ]] || { echo '1B.5 GT1 required or unsafe target' >&2; exit 5; }
[[ "$T" != /opt/* || $EUID -eq 0 ]] || { echo 'Use sudo' >&2; exit 4; }
python3 "$S/release/verify_release_v1.0.0.py" "$S"
install -d -m 0750 "$T/state/locks"; exec 9>"$T/state/locks/framework-global-write.lock"; flock -n 9 || exit 7; exec 8>"$T/state/locks/milestone-1b6.lock"; flock -n 8 || exit 7
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"; B="$T/backups/framework-upgrade/$STAMP"; install -d -m 0750 "$B/files"
python3 "$S/release/create_upgrade_plan_v1.0.0.py" "$S" "$T" "$B"
python3 "$S/release/verify_upgrade_plan_v1.0.0.py" "$B/plan.json" "$B"
STAGE="$(mktemp -d /opt/tcds/.eif-1b6-stage.XXXXXX 2>/dev/null || mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT; cp -a "$T/." "$STAGE/"
python3 "$S/release/apply_plan_v1.0.0.py" "$S" "$STAGE" "$B/plan.json" apply
"$STAGE/tests/backup/test-all.sh"
if ! python3 "$S/release/apply_plan_v1.0.0.py" "$S" "$T" "$B/plan.json" apply || ! "$T/tests/backup/test-all.sh"; then
  python3 "$S/release/apply_plan_v1.0.0.py" "$S" "$T" "$B/plan.json" rollback
  echo 'Installation failed; verified rollback applied' >&2; exit 8
fi
echo "Milestone 1B.6 installed successfully"; echo "Rollback plan: $B/plan.json"
