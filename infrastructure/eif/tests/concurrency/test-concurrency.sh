#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/locks" "$TMP/output"
worker() {
  local n="$1"
  exec 9>>"$TMP/locks/serial.lock"
  flock 9
  printf '%s\n' "$n" >> "$TMP/output/events"
}
for i in $(seq 1 50); do worker "$i" & done
wait
[[ "$(wc -l < "$TMP/output/events")" -eq 50 ]]
[[ "$(sort -n "$TMP/output/events" | uniq | wc -l)" -eq 50 ]]
echo "PASS: concurrency suite"
