#!/usr/bin/env bash
set -Eeuo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.."&&pwd -P)";T="$(mktemp -d)";trap 'rm -rf "$T"' EXIT;cp -a "$R/." "$T/";mkdir -p "$T/config/defaults";cp "$T/config/upgrade/logging-v0.5.0.json" "$T/config/defaults/framework.json";E="$T/framework/logging/log_engine_v2.py"
for i in 1 2 3;do printf '{"message":"m%s","password":"x"}' "$i"|"$E" --root "$T" emit --level INFO >/dev/null;done
"$E" --root "$T" seal --stream framework >/dev/null;"$E" --root "$T" verify --stream framework >/dev/null
! grep -R '"password":"x"' "$T/logs/audit";if "$E" --root "$T" verify --stream '../../../etc/passwd' >/dev/null 2>&1;then exit 1;fi
printf '{"event_type":"envoy_edge","session_id":"s"}'|"$T/framework/telemetry/telemetry_spool.py" --root "$T" >/dev/null;grep -q tcds_telemetry_queue_bytes "$T/logs/telemetry/metrics.prom"
echo PASS-green-tier1
