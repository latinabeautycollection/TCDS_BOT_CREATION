#!/usr/bin/env bash
set -euo pipefail

cd /srv/tcds-retail-bot-repo-clean

set -a
source /srv/pqp/.env
set +a

: "${DATABASE_URL:?DATABASE_URL is required}"

exec 9>/run/lock/tcds-r1e-qualify.lock
if ! flock -n 9; then
  echo "R1E qualification batch already running; skipping"
  exit 0
fi

RULESET_ID="e653854f-5366-4d67-94bf-0f07041a0ce2"

AUTHORITY_STATE="$(
  psql "$DATABASE_URL" -Atqc "
    SELECT
      retail.r1e_r1d_binding_is_current(),
      retail.r1e_latest_certification_is_current(
        '$RULESET_ID'::uuid
      );
  "
)"

if [[ "$AUTHORITY_STATE" != "t|t" ]]; then
  echo "ERROR: R1E production authority is not current: $AUTHORITY_STATE"
  exit 1
fi

export CODE_VERSION="$(git rev-parse HEAD)"
export R1E_ACTOR_NAME="R1E Production Batch"
export R1E_BATCH_LIMIT="${R1E_BATCH_LIMIT:-25}"

exec /usr/bin/node --import tsx \
  scripts/retail-automation/r1e/qualify-batch.ts \
  "$RULESET_ID"
