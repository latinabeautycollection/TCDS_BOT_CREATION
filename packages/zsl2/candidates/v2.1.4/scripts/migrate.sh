#!/usr/bin/env bash
set -euo pipefail
: "${DATABASE_URL:?DATABASE_URL required}"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.tcds_zsl2_migration_history(
  migration_name text PRIMARY KEY,
  sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
  applied_at timestamptz NOT NULL DEFAULT now()
);
SQL
for f in database/migrations/*.sql; do
  name="$(basename "$f")"; sha="$(sha256sum "$f" | awk '{print $1}')"
  existing="$(psql "$DATABASE_URL" -At -v ON_ERROR_STOP=1 -v n="$name" -c "select sha256 from public.tcds_zsl2_migration_history where migration_name=:'n'" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    [[ "$existing" == "$sha" ]] || { echo "MIGRATION_SHA_DRIFT $name expected=$existing actual=$sha" >&2; exit 3; }
    echo "Already applied $name"; continue
  fi
  echo "Applying $name"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v n="$name" -v s="$sha" -c "insert into public.tcds_zsl2_migration_history(migration_name,sha256) values(:'n',:'s')"
done
