#!/usr/bin/env bash
[[ -n "${TCDS_EIF_CONSTANTS_LOADED:-}" ]] && return 0
readonly TCDS_EIF_CONSTANTS_LOADED=1
readonly EIF_NAME="TCDS Enterprise Infrastructure Framework"
readonly EIF_VERSION="0.3.0"
readonly EIF_SCHEMA_VERSION="1.0"
readonly EIF_DEFAULT_ROOT="/opt/tcds/TCDS_Enterprise_Infrastructure"
readonly EIF_EXIT_SUCCESS=0 EIF_EXIT_USAGE=2 EIF_EXIT_COLLISION=3 EIF_EXIT_PERMISSION=4
readonly EIF_EXIT_DEPENDENCY=5 EIF_EXIT_VALIDATION=6 EIF_EXIT_LOCKED=7 EIF_EXIT_RUNTIME=8
readonly EIF_ALLOWED_ENVIRONMENTS_REGEX='^(development|test|staging|production)$'

readonly EIF_EXIT_DRIFT=10
readonly EIF_EXIT_TRANSACTION=11
readonly EIF_EXIT_REGISTRY=12
readonly EIF_EXIT_STATE=13
readonly EIF_EXIT_UPGRADE=14
