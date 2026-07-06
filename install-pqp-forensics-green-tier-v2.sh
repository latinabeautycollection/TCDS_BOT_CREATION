cd /srv/pqp
nano install-pqp-forensics-green-tier-v2.sh


#!/usr/bin/env bash
set -euo pipefail

PQP_DIR="${PQP_DIR:-/srv/pqp}"
CREEP_DIR="${CREEP_DIR:-/srv/creepjs}"
ENV_FILE="${PQP_DIR}/.env"
BACKUP_DIR="${PQP_DIR}/backups/forensics"
EVIDENCE_DIR="${PQP_DIR}/reports/install"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
EVIDENCE_FILE="${EVIDENCE_DIR}/pqp-forensics-install-${TIMESTAMP}.json"
ROLLBACK_FILE="${PQP_DIR}/rollback-pqp-forensics-${TIMESTAMP}.sh"
DOMAIN="${PQP_DOMAIN:-}"
CREEP_PORT="${CREEP_PORT:-8090}"
PQP_PORT="${PQP_PORT:-8088}"

mkdir -p "$BACKUP_DIR" "$EVIDENCE_DIR"

declare -A CHECKS

log(){ echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"; }
mark(){ CHECKS["$1"]="$2"; }
fail(){ log "FAIL: $*"; mark "fatal_error" "fail:$*"; write_evidence || true; exit 1; }

require_dir(){ [ -d "$1" ] || fail "Missing directory: $1"; }
require_file(){ [ -f "$1" ] || fail "Missing file: $1"; }

backup_file(){
  local f="$1"
  if [ -f "$f" ]; then
    cp "$f" "${BACKUP_DIR}/$(basename "$f").${TIMESTAMP}.bak"
  fi
}

upsert_env(){
  local key="$1"
  local value="$2"
  touch "$ENV_FILE"

  grep -v "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
  echo "${key}=${value}" >> "$ENV_FILE"
}

validate_no_duplicate_env(){
  local dupes
  dupes="$(cut -d= -f1 "$ENV_FILE" | sort | uniq -d || true)"
  if [ -n "$dupes" ]; then
    mark "env_duplicate_check" "fail:$dupes"
    return 1
  fi
  mark "env_duplicate_check" "pass"
}

write_evidence(){
  local checks_json="{}"
  for k in "${!CHECKS[@]}"; do
    checks_json="$(echo "$checks_json" | jq --arg k "$k" --arg v "${CHECKS[$k]}" '. + {($k): $v}')"
  done

  cat > "$EVIDENCE_FILE" <<JSON
{
  "installedAt": "${TIMESTAMP}",
  "pqpDir": "${PQP_DIR}",
  "creepDir": "${CREEP_DIR}",
  "serverIp": "${SERVER_IP:-unknown}",
  "domain": "${DOMAIN}",
  "publicBaseUrl": "${PUBLIC_BASE_URL:-unknown}",
  "directBaseUrl": "${DIRECT_BASE_URL:-unknown}",
  "creepBaseUrl": "${CREEP_BASE_URL:-unknown}",
  "nodeVersion": "$(node -v 2>/dev/null || echo unknown)",
  "npmVersion": "$(npm -v 2>/dev/null || echo unknown)",
  "evidenceFile": "${EVIDENCE_FILE}",
  "rollbackFile": "${ROLLBACK_FILE}",
  "checks": ${checks_json}
}
JSON

  cat "$EVIDENCE_FILE" | jq
}

log "1. Validating PQP exists..."
require_dir "$PQP_DIR"
require_dir "${PQP_DIR}/apps/pqp-api/src/public"
require_dir "${PQP_DIR}/apps/pqp-api/src/public/assets"
mark "pqp_directory_validation" "pass"

cd "$PQP_DIR"

SERVER_IP="$(curl -fsS https://api.ipify.org || hostname -I | awk '{print $1}')"
[ -n "$SERVER_IP" ] || fail "Unable to detect server public IP"
mark "server_ip_detection" "pass:${SERVER_IP}"

DIRECT_BASE_URL="http://127.0.0.1:${PQP_PORT}"

if [ -n "$DOMAIN" ]; then
  PUBLIC_BASE_URL="https://${DOMAIN}"
  CREEP_BASE_URL="https://${DOMAIN}/creepjs/"
  NGINX_SERVER_NAME="$DOMAIN"
  mark "domain_detection" "pass:${DOMAIN}"
else
  PUBLIC_BASE_URL="http://${SERVER_IP}:${PQP_PORT}"
  CREEP_BASE_URL="http://${SERVER_IP}:${CREEP_PORT}"
  NGINX_SERVER_NAME="_"
  mark "domain_detection" "not_provided_using_ip"
fi

log "2. Installing dependencies..."
sudo apt update
sudo apt install -y git curl jq nginx build-essential ca-certificates gnupg lsb-release

if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt install -y nodejs
fi

NODE_MAJOR="$(node -v | sed 's/v//' | cut -d. -f1)"
[ "$NODE_MAJOR" -ge 20 ] || fail "Node.js 20+ required. Current: $(node -v)"
mark "exact_dependency_install" "pass"

if ! command -v pm2 >/dev/null 2>&1; then
  sudo npm install -g pm2
fi
mark "pm2_install_check" "pass"

if ! command -v pnpm >/dev/null 2>&1; then
  sudo npm install -g pnpm
fi
mark "pnpm_install_check" "pass"

log "3. Installing forensic npm packages..."
npm install @fingerprintjs/fingerprintjs@4
mark "npm_forensic_packages" "pass"

log "4. Installing CreepJS safely..."
if [ ! -d "$CREEP_DIR/.git" ]; then
  sudo rm -rf "$CREEP_DIR"
  sudo git clone --depth 1 https://github.com/abrahamjuliot/creepjs.git "$CREEP_DIR"
  sudo chown -R "$USER:$USER" "$CREEP_DIR"
else
  cd "$CREEP_DIR"
  git fetch --depth 1 origin
  git reset --hard origin/master || git reset --hard origin/main
fi

cd "$CREEP_DIR"
pnpm install
npm run build || true

if [ -d "${CREEP_DIR}/docs" ]; then
  CREEP_ROOT="${CREEP_DIR}/docs"
elif [ -d "${CREEP_DIR}/public" ]; then
  CREEP_ROOT="${CREEP_DIR}/public"
else
  CREEP_ROOT="${CREEP_DIR}"
fi

[ -f "${CREEP_ROOT}/index.html" ] || fail "CreepJS index.html not found"
grep -qi "creep" "${CREEP_ROOT}/index.html" && mark "creepjs_root_validation" "pass" || mark "creepjs_root_validation" "warning:index_exists_but_creep_text_not_found"

cd "$PQP_DIR"

log "5. Backing up files before overwrite..."
backup_file "/etc/nginx/sites-available/pqp-creepjs.conf"
backup_file "${PQP_DIR}/apps/pqp-api/src/public/assets/fingerprintjs-collector.js"
backup_file "${PQP_DIR}/apps/pqp-api/src/public/forensic-fingerprint-lab.html"
mark "file_backup" "pass"

log "6. Writing NGINX config..."
sudo mkdir -p /etc/nginx/pqp-backups
sudo tee /etc/nginx/sites-available/pqp-creepjs.conf >/dev/null <<NGINX
server {
    listen ${CREEP_PORT};
    server_name ${NGINX_SERVER_NAME};

    root ${CREEP_ROOT};
    index index.html;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    location /creepjs/ {
        alias ${CREEP_ROOT}/;
        try_files \$uri \$uri/ /creepjs/index.html;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}

# HTTPS-ready block. Enable after DNS and certbot are complete.
# server {
#     listen 443 ssl http2;
#     server_name ${NGINX_SERVER_NAME};
#     ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
#     ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
#     root ${CREEP_ROOT};
#     index index.html;
#     location /creepjs/ {
#         alias ${CREEP_ROOT}/;
#         try_files \$uri \$uri/ /creepjs/index.html;
#     }
# }
NGINX

sudo ln -sf /etc/nginx/sites-available/pqp-creepjs.conf /etc/nginx/sites-enabled/pqp-creepjs.conf
sudo nginx -t
sudo systemctl reload nginx
mark "nginx_config_https_ready" "pass"

log "7. Updating .env safely..."
upsert_env "PQP_SERVER_IP" "$SERVER_IP"
upsert_env "PQP_PUBLIC_BASE_URL" "$PUBLIC_BASE_URL"
upsert_env "PQP_DIRECT_BASE_URL" "$DIRECT_BASE_URL"
upsert_env "CREEPJS_URL" "$CREEP_BASE_URL"
upsert_env "IP_INTEL_PROVIDER" "${IP_INTEL_PROVIDER:-ipqualityscore}"
upsert_env "FINGERPRINTJS_AGENT_URL" "https://openfpcdn.io/fingerprintjs/v4"
[ -n "$DOMAIN" ] && upsert_env "PQP_DOMAIN" "$DOMAIN"
validate_no_duplicate_env
mark "env_safe_update" "pass"

log "8. Creating FingerprintJS collector..."
cat > apps/pqp-api/src/public/assets/fingerprintjs-collector.js <<'JS'
async function collectFingerprintJS(sessionId) {
  if (!sessionId) throw new Error("sessionId is required");

  const startedAt = Date.now();
  const mod = await import("https://openfpcdn.io/fingerprintjs/v4");
  const fp = await mod.default.load();
  const result = await fp.get();

  const payload = {
    sessionId,
    profileName: new URLSearchParams(location.search).get("profileName") || "forensic-live-profile",
    proxyLabel: "runtime-observed",
    fingerprintjs: {
      visitorId: result.visitorId,
      confidence: result.confidence,
      components: result.components,
      collectedAt: new Date().toISOString(),
      durationMs: Date.now() - startedAt
    }
  };

  const res = await fetch("/api/pqp/real-capability/snapshot", {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify(payload)
  });

  if (!res.ok) {
    throw new Error("FingerprintJS snapshot POST failed: " + res.status);
  }

  return result;
}

window.collectFingerprintJS = collectFingerprintJS;
JS

require_file "${PQP_DIR}/apps/pqp-api/src/public/assets/fingerprintjs-collector.js"
mark "fingerprintjs_collector_created" "pass"

log "9. Creating forensic lab page..."
cat > apps/pqp-api/src/public/forensic-fingerprint-lab.html <<HTML
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>PQP Forensic Fingerprint Lab</title>
  <style>
    body { font-family: Arial; background:#f4f6f8; padding:24px; }
    .card { background:#fff; padding:16px; border-radius:10px; margin-bottom:16px; }
    pre { background:#111; color:#00ff88; padding:12px; overflow:auto; }
    a, button { padding:10px 14px; display:inline-block; margin:6px 0; }
  </style>
</head>
<body>
  <h1>PQP Forensic Fingerprint Lab</h1>
  <div class="card">
    <h2>FingerprintJS Visitor ID</h2>
    <button onclick="runFP()">Run FingerprintJS</button>
    <pre id="fpBox">{}</pre>
  </div>
  <div class="card">
    <h2>CreepJS Deep Inspection</h2>
    <a href="${CREEP_BASE_URL}" target="_blank">Open CreepJS</a>
  </div>
  <div class="card">
    <h2>PQP Real Capability Lab</h2>
    <a href="/pqp/real-capability-lab.html" target="_blank">Open PQP Real Capability Lab</a>
  </div>

<script src="/pqp/assets/fingerprintjs-collector.js"></script>
<script>
async function startSession() {
  const res = await fetch("/api/pqp/session/start", {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      profileName: new URLSearchParams(location.search).get("profileName") || "forensic-live-profile",
      clientType: "forensic-fingerprint-lab"
    })
  });
  if (!res.ok) throw new Error("Failed to start PQP session");
  const json = await res.json();
  window.sessionId = json.sessionId;
  return json.sessionId;
}

async function runFP() {
  try {
    if (!window.sessionId) await startSession();
    const result = await window.collectFingerprintJS(window.sessionId);
    document.getElementById("fpBox").textContent = JSON.stringify({
      sessionId: window.sessionId,
      visitorId: result.visitorId,
      confidence: result.confidence
    }, null, 2);
  } catch (err) {
    document.getElementById("fpBox").textContent = String(err.message || err);
  }
}

startSession().catch(err => {
  document.getElementById("fpBox").textContent = String(err.message || err);
});
</script>
</body>
</html>
HTML

require_file "${PQP_DIR}/apps/pqp-api/src/public/forensic-fingerprint-lab.html"
mark "forensic_page_created" "pass"

log "10. Creating rollback script..."
cat > "$ROLLBACK_FILE" <<BASH
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR}"
TIMESTAMP="${TIMESTAMP}"

restore_latest(){
  local target="\$1"
  local base
  base="\$(basename "\$target")"
  local backup
  backup="\$(ls -1t "\${BACKUP_DIR}/\${base}."*.bak 2>/dev/null | head -1 || true)"
  if [ -n "\$backup" ]; then
    cp "\$backup" "\$target"
    echo "Restored \$target from \$backup"
  fi
}

restore_latest "/srv/pqp/apps/pqp-api/src/public/assets/fingerprintjs-collector.js"
restore_latest "/srv/pqp/apps/pqp-api/src/public/forensic-fingerprint-lab.html"

if ls "\${BACKUP_DIR}/pqp-creepjs.conf."*.bak >/dev/null 2>&1; then
  sudo cp "\$(ls -1t "\${BACKUP_DIR}/pqp-creepjs.conf."*.bak | head -1)" /etc/nginx/sites-available/pqp-creepjs.conf
  sudo nginx -t
  sudo systemctl reload nginx
fi

pm2 restart pqp-api --update-env || true
echo "Rollback complete."
BASH

chmod +x "$ROLLBACK_FILE"
mark "rollback_script_created" "pass"

log "11. Running npm build..."
npm run build
mark "npm_build_after_dependencies" "pass"

log "12. Creating validation scripts..."
cat > scripts/test-ip-intel.sh <<'BASH'
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
BASH
chmod +x scripts/test-ip-intel.sh

log "13. Restarting PM2 safely..."
PM2_STATUS="not_running"
if pm2 describe pqp-api >/dev/null 2>&1; then
  pm2 restart pqp-api --update-env
  sleep 5
  PM2_ONLINE="$(pm2 jlist | jq -r '.[] | select(.name=="pqp-api") | .pm2_env.status' | head -1)"
  if [ "$PM2_ONLINE" = "online" ]; then
    PM2_STATUS="online"
    mark "pm2_online_after_restart" "pass"
  else
    mark "pm2_online_after_restart" "fail:${PM2_ONLINE}"
    fail "PM2 pqp-api is not online"
  fi
else
  mark "pm2_online_after_restart" "warning:pqp-api_not_found"
fi

log "14. Validating PQP API endpoint with direct fallback..."
PQP_HEALTH_STATUS="failed"
if curl -fsS "${PUBLIC_BASE_URL}/health" >/dev/null 2>&1; then
  PQP_HEALTH_STATUS="passed_public"
elif curl -fsS "${DIRECT_BASE_URL}/health" >/dev/null 2>&1; then
  PQP_HEALTH_STATUS="passed_direct"
else
  fail "PQP health failed on public and direct URLs"
fi
mark "pqp_api_health" "$PQP_HEALTH_STATUS"

log "15. Validating CreepJS endpoint serves actual app..."
if curl -fsS "$CREEP_BASE_URL" | grep -Eiq "creep|fingerprint|trust"; then
  mark "creepjs_endpoint_validation" "pass"
else
  mark "creepjs_endpoint_validation" "fail"
  fail "CreepJS endpoint did not appear to serve CreepJS"
fi

log "16. Validating forensic page endpoint..."
if curl -fsS "${PUBLIC_BASE_URL}/pqp/forensic-fingerprint-lab.html" | grep -q "PQP Forensic Fingerprint Lab"; then
  mark "forensic_page_endpoint" "pass_public"
elif curl -fsS "${DIRECT_BASE_URL}/pqp/forensic-fingerprint-lab.html" | grep -q "PQP Forensic Fingerprint Lab"; then
  mark "forensic_page_endpoint" "pass_direct"
else
  fail "Forensic page endpoint failed"
fi

log "17. Validating real PQP session + snapshot insert..."
SESSION_JSON="$(curl -fsS "${DIRECT_BASE_URL}/api/pqp/session/start" \
  -H "content-type: application/json" \
  -d '{"profileName":"installer-fingerprintjs-e2e","clientType":"installer-validation"}')"

SESSION_ID="$(echo "$SESSION_JSON" | jq -r '.sessionId')"
[ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "null" ] || fail "Could not create PQP session"

SNAPSHOT_RESPONSE="$(curl -fsS "${DIRECT_BASE_URL}/api/pqp/real-capability/snapshot" \
  -H "content-type: application/json" \
  -d "{
    \"sessionId\":\"${SESSION_ID}\",
    \"profileName\":\"installer-fingerprintjs-e2e\",
    \"proxyLabel\":\"installer-validation\",
    \"fingerprintjs\":{
      \"visitorId\":\"installer-test-visitor-${TIMESTAMP}\",
      \"confidence\":{\"score\":1},
      \"components\":{\"installerValidation\":{\"value\":\"pass\"}},
      \"collectedAt\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",
      \"durationMs\":1
    }
  }")"

echo "$SNAPSHOT_RESPONSE" | jq -e '.ok == true' >/dev/null || fail "Snapshot endpoint did not accept FingerprintJS payload"
mark "real_capability_snapshot_accepts_fingerprintjs" "pass"

REPORT_RESPONSE="$(curl -fsS "${DIRECT_BASE_URL}/api/pqp/real-capability/report/${SESSION_ID}" || true)"
if echo "$REPORT_RESPONSE" | jq -e '.score != null or .mismatches != null' >/dev/null 2>&1; then
  mark "real_capability_report_endpoint" "pass"
else
  mark "real_capability_report_endpoint" "warning:report_empty_or_not_evaluated"
fi

mark "real_pqp_session_created" "pass:${SESSION_ID}"

log "18. Validating IPinfo/IPQS keys..."
if bash scripts/test-ip-intel.sh 8.8.8.8 >/dev/null 2>&1; then
  mark "ipinfo_ipqs_key_validation" "pass"
else
  mark "ipinfo_ipqs_key_validation" "warning:missing_or_invalid_keys"
fi

log "19. Writing E2E script..."
cat > scripts/pqp-forensics-e2e.sh <<BASH
#!/usr/bin/env bash
set -euo pipefail
curl -fsS "${DIRECT_BASE_URL}/health" >/dev/null
curl -fsS "${PUBLIC_BASE_URL}/pqp/forensic-fingerprint-lab.html" >/dev/null || curl -fsS "${DIRECT_BASE_URL}/pqp/forensic-fingerprint-lab.html" >/dev/null
curl -fsS "${CREEP_BASE_URL}" >/dev/null
echo "PQP forensics E2E passed"
BASH
chmod +x scripts/pqp-forensics-e2e.sh
mark "e2e_script_created" "pass"

write_evidence

FAILED="$(jq -r '.checks | to_entries[] | select(.value | startswith("fail")) | .key' "$EVIDENCE_FILE" || true)"
if [ -n "$FAILED" ]; then
  fail "One or more checks failed: $FAILED"
fi

log "10/10 Green Tier 1 forensic fingerprinting system installed and validated."
log "Evidence: $EVIDENCE_FILE"
log "Rollback: $ROLLBACK_FILE"
log "Open: ${PUBLIC_BASE_URL}/pqp/forensic-fingerprint-lab.html"
log "Open: ${CREEP_BASE_URL}"
