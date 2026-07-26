#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

TARGET="${EIF_ROOT:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
SOURCE="${1:-/tmp/tcds-eif-milestone-1b2-green-tier1}"
OWNER="${EIF_OWNER:-ingest}"
GROUP="${EIF_GROUP:-ingest}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || fail "Run this recovery as root."
[[ "$TARGET" == "/opt/tcds/TCDS_Enterprise_Infrastructure" ]] ||
  fail "Refusing unexpected EIF_ROOT: $TARGET"
[[ -d "$TARGET" && ! -L "$TARGET" ]] ||
  fail "EIF target is missing or is a symlink: $TARGET"
[[ -f "$TARGET/framework/core/framework.sh" ]] ||
  fail "Milestone 1B.1 core is missing."
[[ -f "$SOURCE/install-green-tier1-upgrade.sh" ]] ||
  fail "Extracted 1B.2 GT1 package not found at: $SOURCE"
id "$OWNER" >/dev/null 2>&1 || fail "Owner account does not exist: $OWNER"
getent group "$GROUP" >/dev/null 2>&1 ||
  fail "Owner group does not exist: $GROUP"

PARENT="$(dirname "$TARGET")"
BACKUP_ROOT="$PARENT/eif-recovery-backups/1b2-$TIMESTAMP"
ORIGINAL="$BACKUP_ROOT/framework-pre-1b2"
FAILED="$BACKUP_ROOT/framework-failed-1b2"
STAGE_CONTAINER="$(mktemp -d "$PARENT/.eif-1b2-stage.XXXXXX")"
STAGE="$STAGE_CONTAINER/framework"
LOCK_FILE="$PARENT/.eif-milestone-1b2-recovery.lock"
SWAPPED=0

cleanup() {
  if [[ -d "$STAGE_CONTAINER" ]]; then
    rm -rf --one-file-system "$STAGE_CONTAINER"
  fi
}

rollback_on_error() {
  local exit_code=$?
  trap - ERR

  if [[ "$SWAPPED" -eq 1 && -d "$ORIGINAL" ]]; then
    printf 'Live validation failed; restoring the pre-1B.2 framework.\n' >&2
    if [[ -d "$TARGET" ]]; then
      mv "$TARGET" "$FAILED"
    fi
    mv "$ORIGINAL" "$TARGET"
  fi

  cleanup
  printf 'Recovery failed with exit code %s.\n' "$exit_code" >&2
  exit "$exit_code"
}

trap rollback_on_error ERR
trap cleanup EXIT

touch "$LOCK_FILE"
chown "$OWNER:$GROUP" "$LOCK_FILE"
chmod 0640 "$LOCK_FILE"
exec 9>"$LOCK_FILE"
flock -n 9 || fail "Another EIF installation or recovery is active."

install -d -m 0750 -o "$OWNER" -g "$GROUP" "$BACKUP_ROOT"
install -d -m 0750 "$STAGE"
cp -a "$TARGET/." "$STAGE/"

overlay_payload() {
  local source_file="$1"
  local relative="${source_file#"$SOURCE/"}"
  local destination="$STAGE/$relative"
  local temporary

  case "$relative" in
    install-*.sh|rollback-*.sh|runtime/*|logs/*|events/*|state/*|backups/*|manifests/*|inventory/reports/*|*/__pycache__/*|*.pyc)
      return
      ;;
  esac

  [[ ! -L "$destination" ]] ||
    fail "Destination symlink collision: $destination"

  install -d -m 0750 "$(dirname "$destination")"
  temporary="$(dirname "$destination")/.${destination##*/}.new.$$"
  install -m 0640 "$source_file" "$temporary"

  case "$relative" in
    *.sh|bin/*|*.py)
      chmod 0750 "$temporary"
      ;;
  esac

  mv -f "$temporary" "$destination"
}

while IFS= read -r -d '' payload_file; do
  overlay_payload "$payload_file"
done < <(find "$SOURCE" -type f -print0)

chown -R "$OWNER:$GROUP" "$STAGE"
find "$STAGE" -type d -exec chmod 0750 {} +
find "$STAGE" -type f -exec chmod 0640 {} +
find "$STAGE/bin" "$STAGE/tests" "$STAGE/framework" \
  -type f \( -name '*.sh' -o -name '*.py' -o -path '*/bin/*' \) \
  -exec chmod 0750 {} +

export EIF_ROOT="$STAGE"
export EIF_ENVIRONMENT=test

"$STAGE/tests/unit/test-core.sh"
"$STAGE/tests/unit/test-config-engine.sh"
"$STAGE/tests/unit/test-secret-references.sh"
"$STAGE/tests/smoke/test-load.sh"
"$STAGE/tests/enterprise/test-green-tier1.sh"

rm -f \
  "$STAGE/state/components/redis.json" \
  "$STAGE/inventory/baselines/gt1-test.json" \
  "$STAGE/inventory/reports/drift-gt1-test.json"

mv "$TARGET" "$ORIGINAL"
SWAPPED=1
mv "$STAGE" "$TARGET"

export EIF_ROOT="$TARGET"
export EIF_ENVIRONMENT=test

"$TARGET/tests/unit/test-core.sh"
"$TARGET/tests/unit/test-config-engine.sh"
"$TARGET/tests/unit/test-secret-references.sh"
"$TARGET/tests/smoke/test-load.sh"

MANIFEST="$TARGET/manifests/installations/milestone-1b2-green-tier1-$TIMESTAMP.json"
install -d -m 0750 -o "$OWNER" -g "$GROUP" "$(dirname "$MANIFEST")"
python3 - "$MANIFEST" "$ORIGINAL" <<'PY'
import datetime
import json
import os
import sys

manifest_path, backup_path = sys.argv[1:]
temporary_path = manifest_path + ".tmp"
payload = {
    "schemaVersion": "1.0",
    "milestone": "1B.2-GT1",
    "frameworkVersion": "0.3.0",
    "status": "SUCCESS",
    "validated": True,
    "backup": backup_path,
    "serviceChanges": False,
    "processSignals": False,
    "firewallChanges": False,
    "installedAtUtc": datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat(),
    "installer": "EIF_1B2_Recovery.sh",
}

with open(temporary_path, "w", encoding="utf-8") as manifest:
    json.dump(payload, manifest, indent=2)
    manifest.write("\n")

os.chmod(temporary_path, 0o640)
os.replace(temporary_path, manifest_path)
PY

chown -R "$OWNER:$GROUP" "$TARGET"
find "$TARGET" -type d -exec chmod 0750 {} +
find "$TARGET" -type f -exec chmod 0640 {} +
find "$TARGET/bin" "$TARGET/tests" "$TARGET/framework" \
  -type f \( -name '*.sh' -o -name '*.py' -o -path '*/bin/*' \) \
  -exec chmod 0750 {} +

SWAPPED=0
trap - ERR

printf '1B.2 Green Tier 1 recovery completed.\n'
printf 'Manifest: %s\n' "$MANIFEST"
printf 'Rollback copy: %s\n' "$ORIGINAL"
