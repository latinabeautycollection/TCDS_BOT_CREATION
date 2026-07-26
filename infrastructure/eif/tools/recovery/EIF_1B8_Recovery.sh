#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

TARGET="${EIF_ROOT:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
SOURCE="${1:-/tmp/tcds-eif-milestone-1b8-green-tier1-v1.5.0}"
OWNER="${EIF_OWNER:-ingest}"
GROUP="${EIF_GROUP:-ingest}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TRUSTED_KEY_SHA256="70226c5442f10f2a2ec01fdae0eb428c9ad725adc063451cbea3ea2d3a2d8563"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || fail "Run this recovery as root."
[[ "$TARGET" == "/opt/tcds/TCDS_Enterprise_Infrastructure" ]] ||
  fail "Refusing unexpected EIF_ROOT: $TARGET"
[[ -d "$TARGET" && ! -L "$TARGET" ]] ||
  fail "EIF target is missing or is a symlink: $TARGET"
[[ -f "$SOURCE/release_v1.5.0/release-manifest.json" ]] ||
  fail "Extracted 1B.8 GT1 package not found at: $SOURCE"
[[ "$(<"$TARGET/VERSION")" == "1.3.0" ]] ||
  fail "Milestone 1B.7 version 1.3.0 is required."
compgen -G \
  "$TARGET/manifests/installations/milestone-1b7-green-tier1-*.json" \
  >/dev/null ||
  fail "A successful Milestone 1B.7 GT1 manifest is required."
[[ -x "$TARGET/bin/eif-validate-v3" ]] ||
  fail "Milestone 1B.7 validation engine is missing."
id "$OWNER" >/dev/null 2>&1 || fail "Owner account does not exist: $OWNER"
getent group "$GROUP" >/dev/null 2>&1 ||
  fail "Owner group does not exist: $GROUP"

for required_command in \
  flock \
  openssl \
  runuser \
  sha256sum \
  systemd-cat \
  /usr/bin/true \
  /usr/bin/sleep \
  /usr/bin/printf \
  /usr/bin/python3
do
  command -v "$required_command" >/dev/null 2>&1 ||
    fail "Required command is unavailable: $required_command"
done

[[ "$(sha256sum "$SOURCE/release_v1.5.0/release-manifest.json" | awk '{print $1}')" == \
  "3eada8fc6cb1f6547830937067da2d7ae032a49bbf83e9fbc1288de35b92da17" ]] ||
  fail "Signed v1.5.0 release manifest checksum mismatch."
[[ "$(sha256sum "$SOURCE/release_v1.5.0/release-public.pem" | awk '{print $1}')" == \
  "$TRUSTED_KEY_SHA256" ]] ||
  fail "Release public-key fingerprint mismatch."
[[ "$(sha256sum "$SOURCE/release_v1.5.0/verify_release.py" | awk '{print $1}')" == \
  "cd010ab32f0b6313aac0297372439f0d474beb8eea4e2db854100f8c8574d186" ]] ||
  fail "Release verifier checksum mismatch."

EIF_TRUSTED_RELEASE_KEY_SHA256="$TRUSTED_KEY_SHA256" \
  python3 "$SOURCE/release_v1.5.0/verify_release.py" "$SOURCE"

PARENT="$(dirname "$TARGET")"
BACKUP_ROOT="$PARENT/eif-recovery-backups/1b8-$TIMESTAMP"
ORIGINAL="$BACKUP_ROOT/framework-pre-1b8"
FAILED="$BACKUP_ROOT/framework-failed-1b8"
STAGE_CONTAINER="$(mktemp -d "$PARENT/.eif-1b8-stage.XXXXXX")"
STAGE="$STAGE_CONTAINER/framework"
LOCK_FILE="$PARENT/.eif-milestone-1b8-recovery.lock"
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
    printf 'Live validation failed; restoring the pre-1B.8 framework.\n' >&2
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

# Overlay signed immutable files while preserving live databases and locks.
python3 - "$SOURCE" "$STAGE" <<'PY'
import json
import os
import pathlib
import shutil
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).resolve()
target = pathlib.Path(sys.argv[2]).resolve()
release_dir = source / "release_v1.5.0"
manifest_path = release_dir / "release-manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
mutable_paths = {
    pathlib.PurePosixPath("state/backup_v2/backup.db"),
    pathlib.PurePosixPath("state/database/state-v0.9.0.sqlite3"),
    pathlib.PurePosixPath(
        "state/locks/backup_v2/backup-not-a-valid-backup.lock"
    ),
}

for entry in manifest["files"]:
    relative = pathlib.PurePosixPath(entry["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit(f"Unsafe release path: {relative}")
    if relative in mutable_paths:
        print(f"PRESERVED mutable path: {relative}")
        continue

    source_file = source.joinpath(*relative.parts)
    destination = target.joinpath(*relative.parts)
    if destination.is_symlink():
        raise SystemExit(f"Destination symlink collision: {destination}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.new.",
        dir=destination.parent,
    )
    os.close(fd)
    temporary = pathlib.Path(temporary_name)

    try:
        shutil.copyfile(source_file, temporary)
        os.chmod(temporary, int(entry["mode"], 8))
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)

# Retain signed release evidence for audit.
audit_dir = target / "release_v1.5.0"
audit_dir.mkdir(parents=True, exist_ok=True)
for name, mode in (
    ("release-manifest.json", 0o640),
    ("release-manifest.sig", 0o640),
    ("release-public.pem", 0o640),
    ("verify_release.py", 0o750),
):
    shutil.copyfile(release_dir / name, audit_dir / name)
    os.chmod(audit_dir / name, mode)
PY

install -d -m 0750 \
  "$STAGE/certification/evidence" \
  "$STAGE/certification/reports" \
  "$STAGE/certification/state" \
  "$STAGE/certification_v2/evidence" \
  "$STAGE/certification_v2/reports" \
  "$STAGE/certification_v2/state"

normalize_permissions() {
  local root="$1"

  chown -R "$OWNER:$GROUP" "$root"
  find "$root" -type d -exec chmod 0750 {} +
  find "$root" -type f -exec chmod 0640 {} +
  find "$root/bin" "$root/tests" "$root/framework" "$root/release" \
    "$root/release_v1.1.0" "$root/release_v1.2.0" \
    "$root/release_v1.3.0" "$root/release_v1.4.0" \
    "$root/release_v1.5.0" \
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

    for test_script in \
      tests/unit/test-core.sh \
      tests/unit/test-config-engine.sh \
      tests/unit/test-secret-references.sh \
      tests/smoke/test-load.sh \
      tests/green-tier1/test-all.sh \
      tests/execution/test-all.sh \
      tests/execution/test-green-tier1.sh \
      tests/state/test-all.sh \
      tests/state_v2/test-all.sh \
      tests/backup/test-all.sh \
      tests/backup_v2/test-all.sh \
      tests/backup_v2/test-negative.sh \
      tests/validation_v2/test-all.sh \
      tests/validation_v2/test-negative.sh \
      tests/validation_v3/test-all.sh \
      tests/certification/test-engine.sh \
      tests/certification_v2/test-engine.sh
    do
      [[ -x "$root/$test_script" ]] ||
        fail "Required validation is missing: $test_script"
      runuser -u "$OWNER" -- env \
        EIF_ROOT="$root" \
        EIF_ENVIRONMENT=test \
        "$root/$test_script"
    done
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

MANIFEST="$TARGET/manifests/installations/milestone-1b8-green-tier1-$TIMESTAMP.json"
install -d -m 0750 -o "$OWNER" -g "$GROUP" "$(dirname "$MANIFEST")"
python3 - "$MANIFEST" "$ORIGINAL" "$TRUSTED_KEY_SHA256" <<'PY'
import datetime
import json
import os
import sys

manifest_path, backup_path, key_fingerprint = sys.argv[1:]
temporary_path = manifest_path + ".tmp"
payload = {
    "schemaVersion": "1.0",
    "milestone": "1B.8-GT1",
    "frameworkVersion": "1.5.0",
    "status": "SUCCESS",
    "validated": True,
    "baseCertificationVersion": "1.4.0",
    "certificationEngineVersion": "1.5.0",
    "certificationMode": "UNIT_TEST",
    "unitTestExpectedGrade": "AMBER",
    "productionCertified": False,
    "mutableStatePreserved": [
        "state/backup_v2/backup.db",
        "state/database/state-v0.9.0.sqlite3",
        "state/locks/backup_v2/backup-not-a-valid-backup.lock",
    ],
    "releaseKeySha256": key_fingerprint,
    "backup": backup_path,
    "serviceChanges": False,
    "processSignals": False,
    "firewallChanges": False,
    "installedAtUtc": datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat(),
    "installer": "EIF_1B8_Recovery.sh",
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

printf '1B.8 Green Tier 1 recovery completed.\n'
printf 'Manifest: %s\n' "$MANIFEST"
printf 'Rollback copy: %s\n' "$ORIGINAL"
printf 'Production certification remains pending live acceptance evidence.\n'
