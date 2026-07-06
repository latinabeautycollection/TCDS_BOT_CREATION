#!/usr/bin/env bash
set -euo pipefail
curl -fsS "http://127.0.0.1:8088/health" >/dev/null
curl -fsS "http://23.239.12.166:8088/pqp/forensic-fingerprint-lab.html" >/dev/null || curl -fsS "http://127.0.0.1:8088/pqp/forensic-fingerprint-lab.html" >/dev/null
curl -fsS "http://23.239.12.166:8090" >/dev/null
echo "PQP forensics E2E passed"
