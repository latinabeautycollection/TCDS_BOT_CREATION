#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/srv/pqp/backups/forensics"
TIMESTAMP="20260613T214053Z"

restore_latest(){
  local target="$1"
  local base
  base="$(basename "$target")"
  local backup
  backup="$(ls -1t "${BACKUP_DIR}/${base}."*.bak 2>/dev/null | head -1 || true)"
  if [ -n "$backup" ]; then
    cp "$backup" "$target"
    echo "Restored $target from $backup"
  fi
}

restore_latest "/srv/pqp/apps/pqp-api/src/public/assets/fingerprintjs-collector.js"
restore_latest "/srv/pqp/apps/pqp-api/src/public/forensic-fingerprint-lab.html"

if ls "${BACKUP_DIR}/pqp-creepjs.conf."*.bak >/dev/null 2>&1; then
  sudo cp "$(ls -1t "${BACKUP_DIR}/pqp-creepjs.conf."*.bak | head -1)" /etc/nginx/sites-available/pqp-creepjs.conf
  sudo nginx -t
  sudo systemctl reload nginx
fi

pm2 restart pqp-api --update-env || true
echo "Rollback complete."
