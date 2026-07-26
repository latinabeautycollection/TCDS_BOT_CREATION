#!/usr/bin/env bash
eif_assert_safe_root(){ [[ "$EIF_ROOT" == /* ]] || return "$EIF_EXIT_USAGE"; case "$EIF_ROOT" in /|/opt|/opt/tcds|/etc|/usr|/var) return "$EIF_EXIT_COLLISION";; esac; [[ ! -L "$EIF_ROOT" ]]; }
eif_require_commands(){ local m=() c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || m+=("$c"); done; ((${#m[@]}==0)) || { printf 'Missing dependencies: %s
' "${m[*]}" >&2; return "$EIF_EXIT_DEPENDENCY"; }; }
eif_bootstrap_directories(){ local d; for d in "$EIF_RUNTIME_DIR" "$EIF_LOG_DIR" "$EIF_STATE_DIR" "$EIF_LOCK_DIR" "$EIF_BACKUP_DIR" "$EIF_MANIFEST_DIR" "$EIF_TMP_DIR"; do [[ ! -L "$d" && !( -e "$d" && ! -d "$d" ) ]] || return "$EIF_EXIT_COLLISION"; install -d -m 0750 "$d"; done; }
eif_bootstrap(){ eif_assert_safe_root; eif_require_commands bash python3 install mv date hostname; eif_bootstrap_directories; eif_discover_environment; eif_initialize_metadata; eif_load_config; }
