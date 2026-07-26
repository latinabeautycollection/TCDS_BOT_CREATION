#!/usr/bin/env bash
if [[ -n "${TCDS_EIF_FRAMEWORK_LOADED:-}" ]]; then return 0 2>/dev/null || exit 0; fi
readonly TCDS_EIF_FRAMEWORK_LOADED=1
set -Eeuo pipefail; IFS=$'\n\t'; umask 027
_CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; EIF_ROOT="${EIF_ROOT:-$(cd "$_CORE/../.." && pwd -P)}"; EIF_ENVIRONMENT="${EIF_ENVIRONMENT:-production}"
source "$_CORE/constants.sh"; source "$_CORE/environment.sh"; source "$_CORE/version.sh"; source "$_CORE/metadata.sh"; source "$_CORE/config.sh"; source "$_CORE/bootstrap.sh"
[[ "$EIF_ENVIRONMENT" =~ $EIF_ALLOWED_ENVIRONMENTS_REGEX ]] || { echo "Invalid EIF_ENVIRONMENT: $EIF_ENVIRONMENT" >&2; return "$EIF_EXIT_USAGE" 2>/dev/null || exit "$EIF_EXIT_USAGE"; }
EIF_RUNTIME_DIR="${EIF_RUNTIME_DIR:-$EIF_ROOT/runtime}"; EIF_LOG_DIR="${EIF_LOG_DIR:-$EIF_ROOT/logs}"; EIF_STATE_DIR="${EIF_STATE_DIR:-$EIF_ROOT/state}"; EIF_LOCK_DIR="${EIF_LOCK_DIR:-$EIF_STATE_DIR/locks}"; EIF_BACKUP_DIR="${EIF_BACKUP_DIR:-$EIF_ROOT/backups}"; EIF_MANIFEST_DIR="${EIF_MANIFEST_DIR:-$EIF_ROOT/manifests}"; EIF_TMP_DIR="${EIF_TMP_DIR:-$EIF_ROOT/tmp}"
export EIF_ROOT EIF_ENVIRONMENT EIF_RUNTIME_DIR EIF_LOG_DIR EIF_STATE_DIR EIF_LOCK_DIR EIF_BACKUP_DIR EIF_MANIFEST_DIR EIF_TMP_DIR
eif_bootstrap

# Enterprise public API
source "$EIF_ROOT/framework/api/public.sh"
