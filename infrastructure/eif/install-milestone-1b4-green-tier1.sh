#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'; umask 027
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
[[ "$T" == /* && ! -L "$T" && -f "$T/framework/execution/execution_engine.py" ]] || { echo "Unsafe target or v0.6.0 missing" >&2; exit 5; }
[[ "$T" != /opt/* || $EUID -eq 0 ]] || { echo "Use sudo" >&2; exit 4; }

python3 "$S/release/verify_release.py" "$S"
install -d -m 0750 "$T/state/locks"
exec 9>"$T/state/locks/framework-global-write.lock"; flock -n 9 || exit 7
exec 8>"$T/state/locks/milestone-1b4-gt1.lock"; flock -n 8 || exit 7

avail="$(df -Pk "$T" | awk 'NR==2{print $4}')"
need="$(du -sk "$T" | awk '{print $1*2}')"
(( avail > need )) || { echo "Insufficient free space" >&2; exit 5; }

B="$T/backups/framework-upgrade/$TS"
install -d -m 0750 "$B/files"
python3 "$S/release/create_backup.py" "$T" "$B"

STAGE="$(mktemp -d -p "$(dirname "$T")" .eif-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$T/." "$STAGE/"
python3 "$S/release/apply_overlay.py" "$S" "$STAGE"
python3 "$STAGE/framework/execution/build_trust_manifest.py" "$STAGE"
EIF_ROOT="$STAGE" "$STAGE/tests/execution/test-green-tier1.sh"
python3 "$S/release/apply_overlay.py" "$S" "$T"
python3 "$T/framework/execution/build_trust_manifest.py" "$T"
EIF_ROOT="$T" "$T/tests/execution/test-green-tier1.sh"
echo "Installed Milestone 1B.4 GT1 v0.7.0"
echo "Backup: $B"
