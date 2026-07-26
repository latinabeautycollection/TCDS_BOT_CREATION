#!/usr/bin/env bash
set -Eeuo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)";T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
[[ "$(cat "$T/VERSION")" == "1.4.0" ]]
python3 "$S/release_v1.5.0/verify_release.py" "$S"
exec 9>"$T/state/locks/framework-global-write.lock";flock -n 9
python3 "$S/release_v1.5.0/apply_overlay.py" "$S" "$T"
EIF_CERTIFICATION_HMAC_KEY=unit EIF_VALIDATION_HMAC_KEY=unit EIF_BACKUP_HMAC_KEY=unit EIF_APPROVAL_HMAC_KEY=unit "$T/tests/certification_v2/test-engine.sh"
echo installed
