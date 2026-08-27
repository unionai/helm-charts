#!/usr/bin/env bash
# Build a Flyte v2 API key from CI credentials, shared by every leg that runs the
# functional tests (the func-v2 cloud legs and the k3d leg).
#
#   build-api-key.sh <host> <client_id> <secret> <org>
#
# With a client_id (selfmanaged / k3d union-test-app), the key is
# base64("host:client_id:secret:org"). With an EMPTY client_id (selfhosted, whose
# secret is already a pre-built cicd FLYTE_API_KEY), the secret is echoed as-is.
set -euo pipefail
host="${1:?host}" ; client_id="${2-}" ; secret="${3:?secret}" ; org="${4-}"
if [ -n "$client_id" ]; then
  # `base64 | tr -d '\n'` (not GNU-only `-w0`) so it also runs on macOS/BSD locally.
  printf '%s:%s:%s:%s' "$host" "$client_id" "$secret" "$org" | base64 | tr -d '\n'
else
  printf '%s' "$secret"
fi
