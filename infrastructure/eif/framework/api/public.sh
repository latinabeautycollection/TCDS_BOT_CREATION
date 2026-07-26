#!/usr/bin/env bash
# shellcheck shell=bash

framework::__enterprise_engine() {
  printf '%s/framework/enterprise/enterprise_engine.py' "$EIF_ROOT"
}
framework::registry::build() {
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" registry-build
}
framework::registry::order() {
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" registry-order "$@"
}
framework::state::get() {
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" state-get "$1"
}
framework::state::transition() {
  local component="$1" target="$2" reason="$3"
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" state-transition "$component" "$target" --reason "$reason"
}
framework::event::publish() {
  local type="$1"; shift
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" event "$type" "$@"
}
framework::inventory::create() {
  local args=()
  [[ -n "${1:-}" ]] && args+=(--component "$1")
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" inventory "${args[@]}"
}
framework::drift::baseline() {
  local name="$1"; shift
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" baseline --name "$name" "$@"
}
framework::drift::check() {
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" drift --name "$1"
}
framework::secret::validate() {
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" secret-validate "$1"
}
framework::transaction::begin() {
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" transaction-begin "$1" "$2"
}
framework::transaction::update() {
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" transaction-update "$1" "$2" "$3" --detail "${4:-}"
}
framework::transaction::finish() {
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" transaction-finish "$1" "$2"
}
framework::doctor() {
  "$(framework::__enterprise_engine)" --root "$EIF_ROOT" doctor
}
