#!/usr/bin/env bash
set -Eeuo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; T="${1:?target}"; B="${2:?backup}"; exec 9>"$T/state/locks/framework-global-write.lock"; flock -n 9 || exit 7; python3 "$S/release/apply_plan_v0.9.0.py" "$S" "$T" "$B/plan.json" rollback
