#!/usr/bin/env python3
"""Verify the repository-safe EIF 1.5.0 source snapshot."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys


EXPECTED_VERSION = "1.5.0"
EXPECTED_MANIFEST_SHA256 = (
    "3eada8fc6cb1f6547830937067da2d7ae032a49bbf83e9fbc1288de35b92da17"
)
EXPECTED_PUBLIC_KEY_SHA256 = (
    "70226c5442f10f2a2ec01fdae0eb428c9ad725adc063451cbea3ea2d3a2d8563"
)

MUTABLE_MANIFEST_PATHS = {
    "state/backup_v2/backup.db",
    "state/database/state-v0.9.0.sqlite3",
    "state/locks/backup_v2/backup-not-a-valid-backup.lock",
}

MUTABLE_SCAFFOLD_DIRS = {
    "backups",
    "backups/blobs",
    "backups/exports",
    "backups/rehearsals",
    "backups/sets",
    "backups_v2",
    "backups_v2/blobs",
    "backups_v2/deadletter",
    "backups_v2/exports",
    "backups_v2/rehearsals",
    "backups_v2/sets",
    "backups_v2/staging",
    "certification",
    "certification/evidence",
    "certification/reports",
    "certification/state",
    "certification_v2",
    "certification_v2/evidence",
    "certification_v2/reports",
    "certification_v2/state",
    "events",
    "health",
    "health/checks",
    "health/metrics",
    "health/reports",
    "health/state",
    "health_v3",
    "health_v3/deadletter",
    "health_v3/metrics",
    "health_v3/reports",
    "health_v3/state",
    "logs",
    "manifests",
    "manifests/installations",
    "runtime",
    "state",
    "state/backup",
    "state/backup_v2",
    "state/checkpoints",
    "state/checkpoints-v2",
    "state/components",
    "state/database",
    "state/executions",
    "state/executions/in-progress",
    "state/executions/integrity",
    "state/executions/receipts",
    "state/exports",
    "state/idempotency",
    "state/locks",
    "state/locks/backup_v2",
    "state/recovery",
    "state/transactions",
    "tmp",
}

PROHIBITED_SUFFIXES = {".db", ".key", ".lock", ".pyc", ".pfx", ".p12", ".sqlite", ".sqlite3"}

RECOVERY_SCRIPT_SHA256 = {
    "EIF_1B2_Recovery.sh": "01a0d6550a769f24381bb5a1fdd80397816bca11ba086fa55eb29f5325e23e18",
    "EIF_1B3_Recovery.sh": "0b002b7c28bbf403d48761c36cc72b668cb593ac2521548b396cead977670fa4",
    "EIF_1B4_Recovery.sh": "6f1e8fb99cc2ae08d17b2254e6665bdce6cec2e4be5ffc7bfb1b22644d7690eb",
    "EIF_1B5_Recovery.sh": "9d5bad3a64f2673af3489d7f4a382e93c3348caf4d6bf7f8212321047d0a45f0",
    "EIF_1B6_Recovery.sh": "d4c53fb6be874645b4352f1453c3b13eeec7612b9cfd31a8e4c06b21d98aad9f",
    "EIF_1B7_Recovery.sh": "482264e5f04186ef0830270897a65eba4a75bd19bebff58a055ba1b302c63491",
    "EIF_1B8_Recovery.sh": "19a9dad46f30c23789dea8d5c593dc04b2a871efe495f762a76d6752d92db783",
}

PRIVATE_KEY_MARKERS = (
    b"BEGIN " + b"PRIVATE KEY",
    b"BEGIN " + b"RSA PRIVATE KEY",
    b"BEGIN " + b"EC PRIVATE KEY",
    b"BEGIN " + b"OPENSSH PRIVATE KEY",
)


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_manifest_path(root: Path, raw_path: object) -> tuple[str, Path]:
    if not isinstance(raw_path, str) or not raw_path:
        fail(f"invalid manifest path: {raw_path!r}")

    relative = PurePosixPath(raw_path)
    if relative.is_absolute() or ".." in relative.parts or "." in relative.parts:
        fail(f"unsafe manifest path: {raw_path}")

    normalized = relative.as_posix()
    path = root.joinpath(*relative.parts)
    if not path.is_relative_to(root):
        fail(f"manifest path escapes snapshot: {raw_path}")
    return normalized, path


def verify_regular_file(path: Path, label: str) -> None:
    try:
        file_stat = path.lstat()
    except FileNotFoundError:
        fail(f"missing {label}: {path}")
    if not stat.S_ISREG(file_stat.st_mode):
        fail(f"{label} is not a regular file: {path}")


def main() -> None:
    if len(sys.argv) != 2:
        fail(f"usage: {Path(sys.argv[0]).name} EIF_SNAPSHOT_ROOT")

    root = Path(sys.argv[1]).expanduser().resolve()
    if not root.is_dir() or root.is_symlink():
        fail(f"snapshot root is not a real directory: {root}")

    version_path = root / "VERSION"
    verify_regular_file(version_path, "VERSION")
    version = version_path.read_text(encoding="utf-8").strip()
    if version != EXPECTED_VERSION:
        fail(f"VERSION is {version!r}, expected {EXPECTED_VERSION!r}")

    release_dir = root / "release_v1.5.0"
    manifest_path = release_dir / "release-manifest.json"
    signature_path = release_dir / "release-manifest.sig"
    public_key_path = release_dir / "release-public.pem"
    for path, label in (
        (manifest_path, "release manifest"),
        (signature_path, "release signature"),
        (public_key_path, "release public key"),
    ):
        verify_regular_file(path, label)

    if sha256(manifest_path) != EXPECTED_MANIFEST_SHA256:
        fail("release manifest hash does not match the approved 1.5.0 manifest")
    if sha256(public_key_path) != EXPECTED_PUBLIC_KEY_SHA256:
        fail("release public-key fingerprint does not match the approved key")

    signature = subprocess.run(
        [
            "openssl",
            "pkeyutl",
            "-verify",
            "-pubin",
            "-inkey",
            str(public_key_path),
            "-rawin",
            "-in",
            str(manifest_path),
            "-sigfile",
            str(signature_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if signature.returncode != 0:
        detail = (signature.stderr or signature.stdout).strip()
        fail(f"release signature verification failed: {detail}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("version") != EXPECTED_VERSION:
        fail(f"manifest version is not {EXPECTED_VERSION}")
    entries = manifest.get("files")
    if not isinstance(entries, list):
        fail("release manifest files field is not an array")

    seen: set[str] = set()
    verified = 0
    skipped: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            fail("release manifest contains a non-object file entry")
        relative, path = safe_manifest_path(root, entry.get("path"))
        if relative in seen:
            fail(f"duplicate manifest path: {relative}")
        seen.add(relative)

        if relative in MUTABLE_MANIFEST_PATHS:
            if path.exists() or path.is_symlink():
                fail(f"mutable runtime artifact must be absent from Git: {relative}")
            skipped.add(relative)
            continue

        verify_regular_file(path, f"signed file {relative}")
        expected_hash = entry.get("sha256")
        if not isinstance(expected_hash, str) or sha256(path) != expected_hash:
            fail(f"hash mismatch: {relative}")

        expected_mode = entry.get("mode")
        actual_mode = f"{stat.S_IMODE(path.stat().st_mode):04o}"
        if expected_mode != actual_mode:
            fail(f"mode mismatch for {relative}: {actual_mode}, expected {expected_mode}")
        verified += 1

    if skipped != MUTABLE_MANIFEST_PATHS:
        missing = sorted(MUTABLE_MANIFEST_PATHS - skipped)
        fail(f"approved mutable exclusions missing from signed manifest: {missing}")

    for relative in sorted(MUTABLE_SCAFFOLD_DIRS):
        path = root / relative
        if not path.is_dir() or path.is_symlink():
            fail(f"required mutable scaffold directory is missing: {relative}")
        if stat.S_IMODE(path.stat().st_mode) != 0o750:
            fail(f"mutable scaffold directory mode is not 0750: {relative}")

    mutable_roots = {path.split("/", 1)[0] for path in MUTABLE_SCAFFOLD_DIRS}
    for mutable_root in sorted(mutable_roots):
        for path in (root / mutable_root).rglob("*"):
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                fail(f"symlink found in mutable scaffold: {relative}")
            if path.is_dir():
                if relative not in MUTABLE_SCAFFOLD_DIRS:
                    fail(f"unapproved mutable scaffold directory: {relative}")
                continue
            if path.name != ".gitkeep" or path.stat().st_size != 0:
                fail(f"generated content found in mutable scaffold: {relative}")
            if stat.S_IMODE(path.stat().st_mode) != 0o640:
                fail(f"mutable scaffold placeholder mode is not 0640: {relative}")

    scanned = 0
    for path in root.rglob("*"):
        if path.is_symlink():
            fail(f"symlinks are prohibited in the source snapshot: {path.relative_to(root)}")
        if not path.is_file():
            continue
        scanned += 1
        if path.suffix.lower() in PROHIBITED_SUFFIXES:
            fail(f"prohibited artifact exists: {path.relative_to(root)}")
        data = path.read_bytes()
        if any(marker in data for marker in PRIVATE_KEY_MARKERS):
            fail(f"private-key material detected: {path.relative_to(root)}")

    recovery_dir = root / "tools" / "recovery"
    for name, expected_hash in RECOVERY_SCRIPT_SHA256.items():
        path = recovery_dir / name
        verify_regular_file(path, f"recovery script {name}")
        if sha256(path) != expected_hash:
            fail(f"recovery script hash mismatch: {name}")
        if stat.S_IMODE(path.stat().st_mode) != 0o750:
            fail(f"recovery script mode is not 0750: {name}")

    print(
        json.dumps(
            {
                "status": "PASS",
                "snapshotRoot": str(root),
                "version": version,
                "signatureVerified": True,
                "signedFilesVerified": verified,
                "mutableSignedFilesExcluded": sorted(skipped),
                "recoveryScriptsVerified": len(RECOVERY_SCRIPT_SHA256),
                "snapshotFilesScanned": scanned,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
