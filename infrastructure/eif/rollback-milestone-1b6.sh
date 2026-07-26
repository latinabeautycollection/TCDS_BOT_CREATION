#!/usr/bin/env bash
set -Eeuo pipefail
T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"; PLAN="${2:?Provide exact plan.json}"
[[ "$T" == /* && "$PLAN" == /* ]] || exit 2
exec 9>"$T/state/locks/framework-global-write.lock"; flock -n 9 || exit 7
B="$(dirname "$PLAN")"; python3 "$T/release/verify_upgrade_plan_v1.0.0.py" "$PLAN" "$B"; python3 "$T/release/apply_plan_v1.0.0.py" "$T" "$T" "$PLAN" rollback
echo 'Milestone 1B.6 rollback completed'
