#!/usr/bin/env bash
eif_generate_uuid(){ [[ -r /proc/sys/kernel/random/uuid ]] && cat /proc/sys/kernel/random/uuid || python3 -c 'import uuid;print(uuid.uuid4())'; }
eif_initialize_metadata(){
  EIF_RUN_ID="${EIF_RUN_ID:-$(eif_generate_uuid)}"
  EIF_CORRELATION_ID="${EIF_CORRELATION_ID:-$(eif_generate_uuid)}"
  EIF_DEPLOYMENT_ID="${EIF_DEPLOYMENT_ID:-deploy-$(date -u +%Y%m%dT%H%M%SZ)-${EIF_RUN_ID:0:8}}"
  EIF_STARTED_AT_UTC="${EIF_STARTED_AT_UTC:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  EIF_SCRIPT_NAME="${EIF_SCRIPT_NAME:-$(basename "${BASH_SOURCE[-1]:-$0}")}"; EIF_GIT_COMMIT=unknown; EIF_GIT_BRANCH=unknown
  export EIF_RUN_ID EIF_CORRELATION_ID EIF_DEPLOYMENT_ID EIF_STARTED_AT_UTC EIF_SCRIPT_NAME EIF_GIT_COMMIT EIF_GIT_BRANCH
}
