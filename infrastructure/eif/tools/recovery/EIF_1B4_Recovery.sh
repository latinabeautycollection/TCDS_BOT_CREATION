#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

TARGET="${EIF_ROOT:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
SOURCE="${1:-/tmp/tcds-eif-milestone-1b4-green-tier1-v0.7.0}"
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
[[ -f "$SOURCE/release/manifest.json" ]] ||
  fail "Extracted 1B.4 GT1 package not found at: $SOURCE"
[[ "$(<"$TARGET/VERSION")" == "0.5.0" ]] ||
  fail "Milestone 1B.3 version 0.5.0 is required."
compgen -G \
  "$TARGET/manifests/installations/milestone-1b3-green-tier1-*.json" \
  >/dev/null ||
  fail "A successful Milestone 1B.3 GT1 manifest is required."
[[ -x "$TARGET/bin/eif-log-v2" ]] ||
  fail "Milestone 1B.3 logging control is missing."
id "$OWNER" >/dev/null 2>&1 || fail "Owner account does not exist: $OWNER"
getent group "$GROUP" >/dev/null 2>&1 ||
  fail "Owner group does not exist: $GROUP"

for required_command in \
  systemd-cat \
  /usr/bin/true \
  /usr/bin/sleep \
  /usr/bin/printf \
  /usr/bin/python3
do
  command -v "$required_command" >/dev/null 2>&1 ||
    fail "Required command is unavailable: $required_command"
done

[[ "$(sha256sum "$SOURCE/release/manifest.json" | awk '{print $1}')" == \
  "626cd2cabdd698ded05478100f0d3f33e4d864426579a02ee5c34440bd6a380c" ]] ||
  fail "Release manifest checksum mismatch."
[[ "$(sha256sum "$SOURCE/release/verify_release.py" | awk '{print $1}')" == \
  "f2ecdda0a1c8f8af0620d66f2bd6b7aceadc31c818d9fc95e5645b593bee7548" ]] ||
  fail "Release verifier checksum mismatch."

python3 "$SOURCE/release/verify_release.py" "$SOURCE"

PARENT="$(dirname "$TARGET")"
BACKUP_ROOT="$PARENT/eif-recovery-backups/1b4-$TIMESTAMP"
ORIGINAL="$BACKUP_ROOT/framework-pre-1b4"
FAILED="$BACKUP_ROOT/framework-failed-1b4"
STAGE_CONTAINER="$(mktemp -d "$PARENT/.eif-1b4-stage.XXXXXX")"
STAGE="$STAGE_CONTAINER/framework"
LOCK_FILE="$PARENT/.eif-milestone-1b4-recovery.lock"
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
    printf 'Live validation failed; restoring the pre-1B.4 framework.\n' >&2
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

install -d -m 0750 \
  "$STAGE/state/executions/in-progress" \
  "$STAGE/state/executions/integrity" \
  "$STAGE/state/executions/receipts" \
  "$STAGE/state/idempotency"

normalize_permissions() {
  local root="$1"

  chown -R "$OWNER:$GROUP" "$root"
  find "$root" -type d -exec chmod 0750 {} +
  find "$root" -type f -exec chmod 0640 {} +
  find "$root/bin" "$root/tests" "$root/framework" "$root/release" \
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

build_trust_manifest() {
  local root="$1"

  (
    cd "$root"
    runuser -u "$OWNER" -- env \
      EIF_ROOT="$root" \
      EIF_ENVIRONMENT=test \
      python3 \
      "$root/framework/execution/build_trust_manifest.py" \
      "$root"
  )
}

run_validation() {
  local root="$1"

  (
    cd "$root"

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

    runuser -u "$OWNER" -- env \
      EIF_ROOT="$root" \
      EIF_ENVIRONMENT=test \
      "$root/tests/execution/test-all.sh"

    runuser -u "$OWNER" -- env \
      EIF_ROOT="$root" \
      EIF_ENVIRONMENT=test \
      "$root/tests/execution/test-green-tier1.sh"
  )
}

normalize_permissions "$STAGE"
build_trust_manifest "$STAGE"
run_validation "$STAGE"
normalize_permissions "$STAGE"
build_trust_manifest "$STAGE"

mv "$TARGET" "$ORIGINAL"
SWAPPED=1
mv "$STAGE" "$TARGET"

build_trust_manifest "$TARGET"
run_validation "$TARGET"

MANIFEST="$TARGET/manifests/installations/milestone-1b4-green-tier1-$TIMESTAMP.json"
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
    "milestone": "1B.4-GT1",
    "frameworkVersion": "0.7.0",
    "status": "SUCCESS",
    "validated": True,
    "baseExecutionVersion": "0.6.0",
    "backup": backup_path,
    "serviceChanges": False,
    "processSignals": False,
    "firewallChanges": False,
    "installedAtUtc": datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat(),
    "installer": "EIF_1B4_Recovery.sh",
}

with open(temporary_path, "w", encoding="utf-8") as manifest:
    json.dump(payload, manifest, indent=2)
    manifest.write("\n")

os.chmod(temporary_path, 0o640)
os.replace(temporary_path, manifest_path)
PY

normalize_permissions "$TARGET"
build_trust_manifest "$TARGET"

SWAPPED=0
trap - ERR

printf '1B.4 Green Tier 1 recovery completed.\n'
printf 'Manifest: %s\n' "$MANIFEST"
printf 'Rollback copy: %s\n' "$ORIGINAL"
