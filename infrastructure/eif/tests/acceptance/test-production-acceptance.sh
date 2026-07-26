#!/usr/bin/env bash
set -Eeuo pipefail
# This script reports host acceptance prerequisites without modifying services.
missing=0
for cmd in python3 openssl sqlite3; do command -v "$cmd" >/dev/null || missing=$((missing+1)); done
[[ -d /run/systemd/system ]] || missing=$((missing+1))
if (( missing > 0 )); then
  echo "Production prerequisites missing: $missing" >&2
  exit 1
fi
echo "PASS: production acceptance baseline"
