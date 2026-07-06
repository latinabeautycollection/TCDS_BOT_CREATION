#!/usr/bin/env bash
set -euo pipefail
source /srv/pqp/.env || true
TEST_IP="${1:-8.8.8.8}"
PASS=true

if [ -n "${IPINFO_TOKEN:-}" ]; then
  curl -fsS "https://ipinfo.io/${TEST_IP}/json?token=${IPINFO_TOKEN}" | jq -e '.ip' >/dev/null || PASS=false
else
  PASS=false
fi

if [ -n "${IPQS_KEY:-}" ]; then
  curl -fsS "https://ipqualityscore.com/api/json/ip/${IPQS_KEY}/${TEST_IP}" | jq -e '.success == true' >/dev/null || PASS=false
else
  PASS=false
fi

[ "$PASS" = "true" ] || exit 1
echo "IP intelligence validation passed"
