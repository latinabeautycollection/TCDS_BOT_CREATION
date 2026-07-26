#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

TARGET="${EIF_ROOT:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
SOURCE="${1:-/tmp/tcds-eif-milestone-1b3-green-tier1-upgrade}"
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
[[ -f "$SOURCE/install-milestone-1b3-green-tier1.sh" ]] ||
  fail "Extracted 1B.3 GT1 package not found at: $SOURCE"
[[ "$(<"$TARGET/VERSION")" == "0.3.0" ]] ||
  fail "Milestone 1B.2 version 0.3.0 is required."
compgen -G \
  "$TARGET/manifests/installations/milestone-1b2-green-tier1-*.json" \
  >/dev/null ||
  fail "A successful Milestone 1B.2 GT1 manifest is required."
id "$OWNER" >/dev/null 2>&1 || fail "Owner account does not exist: $OWNER"
getent group "$GROUP" >/dev/null 2>&1 ||
  fail "Owner group does not exist: $GROUP"
command -v systemd-cat >/dev/null 2>&1 ||
  fail "systemd-cat is required for the 1B.3 logging validation."

declare -A EXPECTED_HASHES=(
  ["framework/logging/log_engine_v2.py"]="86713000a7191be69596de8b1a72da0490955abcc8e1bb8a76f480d175ac0f35"
  ["framework/telemetry/telemetry_spool.py"]="db53316ac3bc4edfe027dc77cccc2382c623925ef1eb817371f96bde0a141706"
  ["bin/eif-log-v2"]="acfadaa714fd8e9e8d75d3e7972b88cfbdb3b5c7b79c8927e64ad96a5e2e7a77"
  ["config/upgrade/logging-v0.5.0.json"]="3bb2780a28d55f34c46cf1d66985235d6f8c1dea74d4b16381ae76575cea59e4"
  ["tests/green-tier1/test-all.sh"]="91943747e7893911b9a8e22789a2e4f098c2c08c9b13391bdc4bd03faf55cfe1"
)

for relative_path in "${!EXPECTED_HASHES[@]}"; do
  payload_file="$SOURCE/$relative_path"
  [[ -f "$payload_file" ]] || fail "Missing payload file: $relative_path"
  actual_hash="$(sha256sum "$payload_file" | awk '{print $1}')"
  [[ "$actual_hash" == "${EXPECTED_HASHES[$relative_path]}" ]] ||
    fail "Payload checksum mismatch: $relative_path"
done

PARENT="$(dirname "$TARGET")"
BACKUP_ROOT="$PARENT/eif-recovery-backups/1b3-$TIMESTAMP"
ORIGINAL="$BACKUP_ROOT/framework-pre-1b3"
FAILED="$BACKUP_ROOT/framework-failed-1b3"
STAGE_CONTAINER="$(mktemp -d "$PARENT/.eif-1b3-stage.XXXXXX")"
STAGE="$STAGE_CONTAINER/framework"
LOCK_FILE="$PARENT/.eif-milestone-1b3-recovery.lock"
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
    printf 'Live validation failed; restoring the pre-1B.3 framework.\n' >&2
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
chown "$OWNER:$GROUP" "$STAGE_CONTAINER"
chmod 0750 "$STAGE_CONTAINER"
install -d -m 0750 "$STAGE"
cp -a "$TARGET/." "$STAGE/"

overlay_payload() {
  local source_file="$1"
  local relative="${source_file#"$SOURCE/"}"
  local destination="$STAGE/$relative"
  local temporary

  case "$relative" in
    install-*.sh|rollback-*.sh|*/__pycache__/*|*.pyc)
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

while IFS= read -r -d '' source_file; do
  overlay_payload "$source_file"
done < <(find "$SOURCE" -type f -print0)

python3 - \
  "$STAGE/config/defaults/framework.json" \
  "$STAGE/config/upgrade/logging-v0.5.0.json" <<'PY'
import json
import os
import sys
import tempfile

config_path, overlay_path = sys.argv[1:]

with open(config_path, encoding="utf-8") as source:
    config = json.load(source)

with open(overlay_path, encoding="utf-8") as source:
    overlay = json.load(source)


def merge(existing, incoming):
    for key, value in incoming.items():
        if (
            isinstance(value, dict)
            and isinstance(existing.get(key), dict)
        ):
            merge(existing[key], value)
        else:
            existing[key] = value
    return existing


merged = merge(config, overlay)
directory = os.path.dirname(config_path)
fd, temporary_path = tempfile.mkstemp(
    prefix=".framework.json.",
    dir=directory,
)

try:
    os.fchmod(fd, 0o640)
    with os.fdopen(fd, "w", encoding="utf-8") as destination:
        json.dump(merged, destination, indent=2)
        destination.write("\n")
        destination.flush()
        os.fsync(destination.fileno())
    os.replace(temporary_path, config_path)
finally:
    if os.path.exists(temporary_path):
        os.unlink(temporary_path)
PY

printf '0.5.0\n' > "$STAGE/VERSION"

normalize_permissions() {
  local root="$1"

  chown -R "$OWNER:$GROUP" "$root"
  find "$root" -type d -exec chmod 0750 {} +
  find "$root" -type f -exec chmod 0640 {} +
  find "$root/bin" "$root/tests" "$root/framework" \
    -type f \( -name '*.sh' -o -name '*.py' -o -path '*/bin/*' \) \
    -exec chmod 0750 {} +

  for runtime_file in \
    "$root/runtime/resolved-config.json" \
    "$root/runtime/resolved-config.json.meta.json"
  do
    if [[ -f "$runtime_file" ]]; then
      chmod 0600 "$runtime_file"
    fi
  done
}

run_validation() {
  local root="$1"

  runuser -u "$OWNER" -- env \
    EIF_ROOT="$root" \
    EIF_ENVIRONMENT=test \
    "$root/tests/unit/test-core.sh"

  runuser -u "$OWNER" -- env \
    EIF_ROOT="$root" \
    EIF_ENVIRONMENT=test \
    "$root/tests/unit/test-config-engine.sh"

  runuser -u "$OWNER" -- env \
    EIF_ROOT="$root" \
    EIF_ENVIRONMENT=test \
    "$root/tests/unit/test-secret-references.sh"

  runuser -u "$OWNER" -- env \
    EIF_ROOT="$root" \
    EIF_ENVIRONMENT=test \
    "$root/tests/smoke/test-load.sh"

  runuser -u "$OWNER" -- env \
    EIF_ROOT="$root" \
    EIF_ENVIRONMENT=test \
    "$root/tests/green-tier1/test-all.sh"
}

normalize_permissions "$STAGE"
run_validation "$STAGE"
normalize_permissions "$STAGE"

mv "$TARGET" "$ORIGINAL"
SWAPPED=1
mv "$STAGE" "$TARGET"

run_validation "$TARGET"

MANIFEST="$TARGET/manifests/installations/milestone-1b3-green-tier1-$TIMESTAMP.json"
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
    "milestone": "1B.3-GT1",
    "frameworkVersion": "0.5.0",
    "status": "SUCCESS",
    "validated": True,
    "backup": backup_path,
    "serviceChanges": False,
    "processSignals": False,
    "firewallChanges": False,
    "installedAtUtc": datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat(),
    "installer": "EIF_1B3_Recovery.sh",
}

with open(temporary_path, "w", encoding="utf-8") as manifest:
    json.dump(payload, manifest, indent=2)
    manifest.write("\n")

os.chmod(temporary_path, 0o640)
os.replace(temporary_path, manifest_path)
PY

normalize_permissions "$TARGET"

SWAPPED=0
trap - ERR

printf '1B.3 Green Tier 1 recovery completed.\n'
printf 'Manifest: %s\n' "$MANIFEST"
printf 'Rollback copy: %s\n' "$ORIGINAL"
